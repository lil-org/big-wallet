// ∅ 2026 lil org

import Cocoa
import LocalAuthentication

struct PendingWalletOpenIntent {
    private(set) var isPending = false

    mutating func record() {
        isPending = true
    }

    mutating func cancel() {
        isPending = false
    }

    mutating func consume() -> Bool {
        let shouldOpenWallet = isPending
        isPending = false
        return shouldOpenWallet
    }
}

struct DockOnboardingHandoff {
    private(set) var isInFlight = false

    mutating func begin() -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        return true
    }

    mutating func finish(succeeded: Bool) -> Bool {
        guard isInFlight else { return false }
        isInFlight = false
        return succeeded
    }
}

@MainActor
final class NativeApprovalWindowCloseObserver {

    private let onClose: () -> Void
    private var notificationObserver: NSObjectProtocol?
    private var isEnabled = true

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func observe(_ window: NSWindow) {
        removeNotificationObserver()
        guard isEnabled else { return }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.onClose()
            }
        }
    }

    func disable() {
        isEnabled = false
        removeNotificationObserver()
    }

    private func removeNotificationObserver() {
        guard let notificationObserver else { return }
        NotificationCenter.default.removeObserver(notificationObserver)
        self.notificationObserver = nil
    }

    deinit {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
    }

}

@MainActor
class Agent: NSObject {
    
    @MainActor
    final class WeakViewControllerReference {
        weak var value: NSViewController?

        func reactivateWindow() {
            guard let value,
                  let window = value.viewIfLoaded?.window,
                  window.contentViewController === value else { return }
            window.deminiaturize(nil)
            Window.activateWindow(window)
        }
    }

    enum LocalAuthenticationResolution: Equatable {
        case authenticated
        case showPassword
        case failed
    }

    enum MissingPasswordApprovalAction: Equatable {
        case awaitOnboarding
        case rejectAndOpenDock
    }

    enum FinishedApprovalWindowAction: Equatable {
        case none
        case close
        case closeAndActivate
    }

    enum ReceiptOwnedCancellationAction: Equatable {
        case finish
        case reject
        case retainForAuthenticationRetry
    }

    @MainActor
    private final class ActiveApproval {
        let coordinator: NativeApprovalCoordinator
        private let windowCloseObserver: NativeApprovalWindowCloseObserver
        private var sharedReviewCleanup: (() -> Void)?
        private(set) var acceptsReviewActions = true
        var bootstrapTask: Task<Void, Never>?
        var windowController: NSWindowController? {
            didSet {
                if let window = windowController?.window {
                    windowCloseObserver.observe(window)
                }
            }
        }

        init(coordinator: NativeApprovalCoordinator) {
            self.coordinator = coordinator
            windowCloseObserver = NativeApprovalWindowCloseObserver(
                onClose: Agent.rejectionHandler(for: coordinator)
            )
        }

        func activate() {
            guard let windowController,
                  windowController.window != nil else {
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            Window.reactivateWindow(windowController)
        }

        func disableRejectionOnWindowClose() {
            windowCloseObserver.disable()
        }

        func beginReview(
            sharedCleanup: (() -> Void)? = nil
        ) {
            sharedReviewCleanup = sharedCleanup
        }

        func endReview() {
            bootstrapTask?.cancel()
            bootstrapTask = nil
            acceptsReviewActions = false
            sharedReviewCleanup?()
            sharedReviewCleanup = nil
            (windowController?.contentViewController as?
                NativeApprovalReviewTeardown)?
                .invalidateNativeApprovalReview()
        }

        deinit {
            bootstrapTask?.cancel()
        }
    }
    
    static let shared = Agent()
    private var didStart = false
    private var isReady = false
    private var didEnterPasswordOnStart = false
    private var isAuthenticatingOnStart = false
    private let startupAuthenticationPresentation = WeakViewControllerReference()
    private var welcomeWindowController: NSWindowController?
    private var welcomeWindowCloseObserver: NativeApprovalWindowCloseObserver?
    private var walletWindowController: NSWindowController?
    private var pendingWalletOpenIntent = PendingWalletOpenIntent()
    private var dockOnboardingHandoff = DockOnboardingHandoff()
    private var runtimeInstanceIdentifier: UUID?
    private var nativeDeliveryOwner: ExtensionBridge.NativeDeliveryOwner?
    private var approvalInbox = ApprovalInbox<ActiveApproval>()

    private override init() {
        super.init()
    }
    
    private var hasPassword: Bool {
        Keychain.shared.password != nil
    }

    func start(
        openOnLaunch: Bool,
        runtimeIdentity: AmbientRuntimeIdentity? = nil
    ) {
        if let runtimeIdentity,
           let owner = runtimeIdentity.nativeDeliveryOwner {
            runtimeInstanceIdentifier = runtimeIdentity.instanceIdentifier
            nativeDeliveryOwner = owner
            isReady = true
        } else if CurrentApp.isDockApp {
            isReady = true
        }
        if !didStart {
            didStart = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(walletsChanged),
                name: .walletsChanged,
                object: nil
            )
        }
        if openOnLaunch {
            pendingWalletOpenIntent.record()
        }
        resumePendingWork()
    }

    func process(route: NativeAgentRoute) {
        start(openOnLaunch: false)
        switch route {
        case .approval(_, let handle, let nativeDeliveryNonce):
            let key = ApprovalRouteKey(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce
            )
            guard approvalInbox.register(key) else {
                if approvalInbox.isAwaitingAuthentication(key) {
                    resumePendingWork()
                    startupAuthenticationPresentation.reactivateWindow()
                } else {
                    reactivateApprovalIfNeeded(for: key)
                }
                return
            }
            startPendingApprovalValidations()
        case .showWallet:
            open()
        }
    }

    func open() {
        start(openOnLaunch: false)
        pendingWalletOpenIntent.record()
        resumePendingWork()
        startupAuthenticationPresentation.reactivateWindow()
    }

    static func missingPasswordApprovalAction(
        canCreatePassword: Bool
    ) -> MissingPasswordApprovalAction {
        canCreatePassword ? .awaitOnboarding : .rejectAndOpenDock
    }

    private func resumePendingWork() {
        guard isReady else { return }
        startPendingApprovalValidations()

        guard hasPassword else {
            guard pendingWalletOpenIntent.isPending ||
                    approvalInbox.hasAwaitingAuthentication else { return }
            if CurrentApp.canCreatePassword {
                showWelcomeIfNeeded()
            } else {
                requestDockOnboarding()
            }
            return
        }

        if didEnterPasswordOnStart {
            activateAwaitingApprovals()
            if pendingWalletOpenIntent.consume() {
                showWallet()
            }
        } else if pendingWalletOpenIntent.isPending ||
                    approvalInbox.hasAwaitingAuthentication {
            requestStartupAuthenticationIfNeeded()
        }
    }

    private func requestStartupAuthenticationIfNeeded() {
        guard !isAuthenticatingOnStart else { return }
        isAuthenticatingOnStart = true
        askAuthentication(
            on: nil,
            browser: nil,
            onStart: true,
            reason: .start
        ) { [weak self] success in
            guard let self else { return }
            self.isAuthenticatingOnStart = false
            self.startupAuthenticationPresentation.value = nil
            guard success else {
                self.pendingWalletOpenIntent.cancel()
                self.cancelPendingApprovals()
                return
            }
            self.didEnterPasswordOnStart = true
            self.resumePendingWork()
        }
    }
    
    @discardableResult
    func askAuthentication(
        on: NSWindow?,
        getBackTo: NSViewController? = nil,
        browser: Browser? = nil,
        onStart: Bool,
        reason: AuthenticationReason,
        onWindowClose: (() -> Void)? = nil,
        completion: @escaping (Bool) -> Void
    ) -> LAContext? {
        let context = LAContext()
        var error: NSError?
        let canDoLocalAuthentication = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
        
        func showPasswordScreen() {
            let window = on ?? Window.showNew(closeOthers: onStart).window
            let presentation = WeakViewControllerReference()
            let passwordViewController = PasswordViewController.with(
                mode: .enter,
                reason: reason,
                windowCloseCompletion: onWindowClose
            ) { [weak window] success in
                guard window?.contentViewController === presentation.value
                else { return }
                if let getBackTo {
                    window?.contentViewController = getBackTo
                } else if let browser {
                    Window.closeWindowAndActivateNext(
                        idToClose: window?.windowNumber,
                        specificBrowser: browser
                    )
                } else {
                    Window.closeWindow(idToClose: window?.windowNumber)
                }
                completion(success)
            }
            presentation.value = passwordViewController
            window?.contentViewController = passwordViewController
            if onStart {
                startupAuthenticationPresentation.value = passwordViewController
            }
        }
        
        guard canDoLocalAuthentication else {
            showPasswordScreen()
            return nil
        }

        context.localizedCancelTitle = Strings.cancel
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason.title
        ) { success, _ in
            DispatchQueue.main.async {
                switch Self.localAuthenticationResolution(
                    success: success,
                    onStart: onStart
                ) {
                case .authenticated:
                    completion(true)
                case .showPassword:
                    showPasswordScreen()
                case .failed:
                    completion(false)
                }
            }
        }
        return context
    }

    static func localAuthenticationResolution(
        success: Bool,
        onStart: Bool
    ) -> LocalAuthenticationResolution {
        if success { return .authenticated }
        return onStart ? .showPassword : .failed
    }
        
    private func startPendingApprovalValidations() {
        guard isReady else { return }
        for key in approvalInbox.takeUnstartedValidations() {
            Task { [weak self] in
                let result = await ExtensionBridge.shared.load(
                    handle: key.handle
                )
                self?.completeApprovalValidation(result, for: key)
            }
        }
    }

    private func completeApprovalValidation(
        _ result: ExtensionBridge.SnapshotResult,
        for key: ApprovalRouteKey
    ) {
        guard approvalInbox.isValidating(key) else { return }
        switch result {
        case .found(let snapshot):
            guard snapshot.nativeDeliveryNonce == key.nativeDeliveryNonce,
                  snapshot.phase != .responded else {
                approvalInbox.remove(key)
                return
            }
            beginApprovalReceiptAcquisition(snapshot: snapshot, for: key)
        case .missing, .unavailable:
            approvalInbox.remove(key)
        }
    }

    private func beginApprovalReceiptAcquisition(
        snapshot: ExtensionBridge.Snapshot,
        for key: ApprovalRouteKey
    ) {
        guard let runtimeInstanceIdentifier,
              let nativeDeliveryOwner,
              approvalInbox.beginReceiptAcquisition(
                  key,
                  order: .init(
                      createdAt: snapshot.createdAt,
                      sequence: snapshot.sequence
                  )
              ) else {
            approvalInbox.remove(key)
            return
        }
        var deadline = Date().addingTimeInterval(ExtensionBridge.requestTTL)
        if let request = snapshot.request {
            deadline = min(deadline, request.admissionDeadline)
        }
        Task { [weak self] in
            var retryDelay: UInt64 = 250_000_000
            while !Task.isCancelled, Date() < deadline {
                switch await ExtensionBridge.shared.recordNativeDeliveryReceipt(
                    handle: key.handle,
                    nativeDeliveryNonce: key.nativeDeliveryNonce,
                    runtimeInstanceIdentifier: runtimeInstanceIdentifier,
                    owner: nativeDeliveryOwner
                ) {
                case .persisted:
                    self?.completeApprovalReceiptAcquisition(key)
                    return
                case .ownershipLost:
                    self?.finishApprovalReceiptAcquisition(key)
                    return
                case .retryablePersistenceFailure:
                    break
                }
                let remaining = max(0, deadline.timeIntervalSinceNow)
                let remainingNanoseconds = UInt64(min(
                    remaining * 1_000_000_000,
                    Double(UInt64.max)
                ))
                try? await Task.sleep(
                    nanoseconds: min(retryDelay, remainingNanoseconds)
                )
                retryDelay = min(retryDelay * 2, 5_000_000_000)
            }
            self?.finishApprovalReceiptAcquisition(key)
        }
    }

    private func completeApprovalReceiptAcquisition(_ key: ApprovalRouteKey) {
        guard let disposition = approvalInbox.receiptAcquired(key) else {
            return
        }
        switch disposition {
        case .awaitAuthentication:
            handleReceiptOwnedApproval(key)
        case .cancel:
            rejectCanceledApproval(key, receiptOwned: true)
        }
    }

    private func finishApprovalReceiptAcquisition(_ key: ApprovalRouteKey) {
        guard approvalInbox.isAcquiringReceipt(key) else { return }
        approvalInbox.remove(key)
    }

    private func handleReceiptOwnedApproval(_ key: ApprovalRouteKey) {
        guard approvalInbox.isAwaitingAuthentication(key) else { return }
        guard hasPassword else {
            switch Self.missingPasswordApprovalAction(
                canCreatePassword: CurrentApp.canCreatePassword
            ) {
            case .awaitOnboarding:
                resumePendingWork()
            case .rejectAndOpenDock:
                guard approvalInbox.markOwnedAsCanceling(key) else { return }
                rejectCanceledApproval(key, receiptOwned: true)
                requestDockOnboarding()
            }
            return
        }
        if didEnterPasswordOnStart {
            activateApproval(key)
        } else {
            resumePendingWork()
        }
    }

    private func activateAwaitingApprovals() {
        for key in approvalInbox.awaitingAuthenticationKeys {
            activateApproval(key)
        }
    }

    private func cancelPendingApprovals() {
        for cancellation in approvalInbox.markPendingAsCanceling() {
            rejectCanceledApproval(
                cancellation.key,
                receiptOwned: cancellation.receiptOwned
            )
        }
    }

    private func rejectCanceledApproval(
        _ key: ApprovalRouteKey,
        receiptOwned: Bool
    ) {
        let runtimeInstanceIdentifier = self.runtimeInstanceIdentifier
        Task { [weak self] in
            var retryDelay: UInt64 = 250_000_000
            var deadline = Date().addingTimeInterval(ExtensionBridge.requestTTL)
            while !Task.isCancelled, Date() < deadline {
                switch await ExtensionBridge.shared.load(handle: key.handle) {
                case .found(let snapshot):
                    guard snapshot.nativeDeliveryNonce ==
                            key.nativeDeliveryNonce else {
                        self?.finishCancelingApproval(key)
                        return
                    }
                    if let request = snapshot.request {
                        deadline = min(deadline, request.admissionDeadline)
                    }
                    guard snapshot.phase != .responded else {
                        self?.finishCancelingApproval(key)
                        return
                    }
                    let result: ExtensionBridge.StoreMutationResult
                    if receiptOwned {
                        switch Self.receiptOwnedCancellationAction(
                            snapshot: snapshot,
                            key: key,
                            runtimeInstanceIdentifier:
                                runtimeInstanceIdentifier
                        ) {
                        case .finish:
                            self?.finishCancelingApproval(key)
                            return
                        case .reject:
                            guard let runtimeInstanceIdentifier else {
                                self?.finishCancelingApproval(key)
                                return
                            }
                            result = await ExtensionBridge.shared
                                .rejectNativeDelivery(
                                    handle: key.handle,
                                    nativeDeliveryNonce:
                                        key.nativeDeliveryNonce,
                                    runtimeInstanceIdentifier:
                                        runtimeInstanceIdentifier
                                )
                        case .retainForAuthenticationRetry:
                            self?.approvalInbox
                                .restoreAwaitingAuthentication(key)
                            return
                        }
                    } else {
                        guard snapshot.nativeDeliveryReceipt == nil,
                              !snapshot.nativeDecisionStaged,
                              snapshot.phase == .queued else {
                            self?.finishCancelingApproval(key)
                            return
                        }
                        result = await ExtensionBridge.shared.reject(
                            handle: key.handle
                        )
                    }
                    switch result {
                    case .persisted:
                        self?.finishCancelingApproval(key)
                        return
                    case .ownershipLost, .retryablePersistenceFailure:
                        break
                    }
                case .missing:
                    self?.finishCancelingApproval(key)
                    return
                case .unavailable:
                    break
                }
                let remaining = max(0, deadline.timeIntervalSinceNow)
                let remainingNanoseconds = UInt64(min(
                    remaining * 1_000_000_000,
                    Double(UInt64.max)
                ))
                try? await Task.sleep(
                    nanoseconds: min(retryDelay, remainingNanoseconds)
                )
                retryDelay = min(retryDelay * 2, 5_000_000_000)
            }
            if receiptOwned {
                self?.approvalInbox.restoreAwaitingAuthentication(key)
            } else {
                self?.finishCancelingApproval(key)
            }
        }
    }

    static func receiptOwnedCancellationAction(
        snapshot: ExtensionBridge.Snapshot,
        key: ApprovalRouteKey,
        runtimeInstanceIdentifier: UUID?
    ) -> ReceiptOwnedCancellationAction {
        guard let runtimeInstanceIdentifier,
              snapshot.nativeDeliveryReceipt?.matches(
                  nativeDeliveryNonce: key.nativeDeliveryNonce,
                  runtimeInstanceIdentifier: runtimeInstanceIdentifier
              ) == true,
              snapshot.phase == .queued else { return .finish }
        return snapshot.nativeDecisionStaged
            ? .retainForAuthenticationRetry
            : .reject
    }

    func applicationDidBecomeActive() {
        guard approvalInbox.hasAwaitingAuthentication else { return }
        resumePendingWork()
    }

    private func finishCancelingApproval(_ key: ApprovalRouteKey) {
        guard approvalInbox.isCanceling(key) else { return }
        approvalInbox.remove(key)
    }

    private func requestDockOnboarding() {
        guard dockOnboardingHandoff.begin() else { return }
        DockAppLauncher.openDockApp { [weak self] succeeded in
            guard let self,
                  dockOnboardingHandoff.finish(succeeded: succeeded) else {
                return
            }
            pendingWalletOpenIntent.cancel()
        }
    }

    private func showWelcomeIfNeeded() {
        if let windowController = welcomeWindowController,
           let window = windowController.window,
           Window.isVisibleContentWindow(window) {
            window.deminiaturize(nil)
            Window.activateWindow(window)
            return
        }
        clearWelcomeWindowOwnership()
        let windowController = Window.showNew(closeOthers: true)
        welcomeWindowController = windowController
        let closeObserver = NativeApprovalWindowCloseObserver {
            [weak self, weak windowController] in
            self?.clearWelcomeWindowOwnership(matching: windowController)
        }
        welcomeWindowCloseObserver = closeObserver
        if let window = windowController.window {
            closeObserver.observe(window)
        }
        let welcomeViewController = WelcomeViewController.new {
            [weak self] createdPassword in
            guard let self else { return }
            if createdPassword {
                self.didEnterPasswordOnStart = true
            } else {
                guard self.hasPassword else { return }
                self.didEnterPasswordOnStart = false
            }
            self.resumePendingWork()
        }
        windowController.contentViewController = welcomeViewController
    }

    private func clearWelcomeWindowOwnership(
        matching windowController: NSWindowController? = nil
    ) {
        if let windowController,
           welcomeWindowController !== windowController {
            return
        }
        welcomeWindowCloseObserver?.disable()
        welcomeWindowCloseObserver = nil
        welcomeWindowController = nil
    }

    private func showWallet() {
        if let walletWindowController,
           let window = walletWindowController.window,
           Window.isVisibleContentWindow(window) {
            Window.reactivateWindow(walletWindowController)
            return
        }
        let accountsList = instantiate(AccountsListViewController.self)
        let windowController = Window.showNew(closeOthers: CurrentApp.isDockApp)
        windowController.contentViewController = accountsList
        walletWindowController = windowController
    }

    private func activateApproval(_ key: ApprovalRouteKey) {
        guard let runtimeInstanceIdentifier else {
            approvalInbox.remove(key)
            return
        }
        let handle = key.handle
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: key.nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier,
            requiresExistingReceipt: true
        )
        let approval = ActiveApproval(coordinator: coordinator)
        guard approvalInbox.activate(approval, for: key) else { return }
        coordinator.onDecisionStaged = { [weak self, weak coordinator] in
            guard let self, let coordinator,
                  let approval = self.activeApproval(
                      for: handle,
                      coordinator: coordinator
                  ) else { return }
            approval.disableRejectionOnWindowClose()
            self.showWaiting(for: handle, coordinator: coordinator)
        }
        coordinator.onFailure = { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            self.showFailureSurface(
                for: handle,
                coordinator: coordinator
            )
        }
        coordinator.onFinished = { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            self.finishApproval(handle: handle, coordinator: coordinator)
        }

        approval.bootstrapTask = Task { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            let presentation = await coordinator.loadPresentation()
            guard self.activeApproval(
                for: handle,
                coordinator: coordinator
            ) != nil else { return }
            self.present(
                presentation,
                for: handle,
                coordinator: coordinator
            )
        }
    }

    private func present(
        _ presentation: NativeApprovalCoordinator.Presentation,
        for handle: ExtensionBridge.Handle,
        coordinator: NativeApprovalCoordinator
    ) {
        switch presentation {
        case .approval(let request, let action):
            present(
                action: action,
                peer: request.peerMeta,
                for: handle,
                coordinator: coordinator
            )
        case .waiting:
            activeApproval(
                for: handle,
                coordinator: coordinator
            )?.disableRejectionOnWindowClose()
            showWaiting(for: handle, coordinator: coordinator)
        case .rejecting:
            showFailureSurface(for: handle, coordinator: coordinator)
        case .finished:
            finishApproval(handle: handle, coordinator: coordinator)
        case .superseded:
            discardApproval(handle: handle, coordinator: coordinator)
        }
    }

    private func present(
        action: DappRequestAction,
        peer: PeerMeta,
        for handle: ExtensionBridge.Handle,
        coordinator: NativeApprovalCoordinator
    ) {
        guard let windowController = approvalWindow(
            peer: peer,
            for: handle,
            coordinator: coordinator
        ) else { return }
        switch action {
        case .selectAccount(let action):
            presentAccountSelection(
                action,
                mode: .selectAccount,
                windowController: windowController,
                for: handle,
                coordinator: coordinator
            )
        case .switchAccount(let action):
            presentAccountSelection(
                action,
                mode: .switchAccount,
                windowController: windowController,
                for: handle,
                coordinator: coordinator
            )
        case .approveMessage(let action):
            showApprove(
                windowController: windowController,
                browser: .safari,
                subject: action.subject,
                meta: action.meta,
                account: action.account,
                walletId: action.walletId,
                solanaClusterSelection: action.solanaClusterSelection
            ) { [weak self, weak coordinator] approved in
                guard let self, let coordinator,
                      self.acceptsReviewAction(
                          for: handle,
                          coordinator: coordinator
                      ) else { return }
                if approved {
                    coordinator.approveMessage(
                        solanaCluster:
                            action.solanaClusterSelection?.selectedCluster
                    )
                } else {
                    coordinator.reject()
                }
            }
            activeApproval(
                for: handle,
                coordinator: coordinator
            )?.beginReview()
        case .approveTransaction(let action):
            showApprove(
                windowController: windowController,
                transaction: action.transaction,
                account: action.account,
                walletId: action.walletId,
                chain: action.chain
            ) { [weak self, weak coordinator] transaction in
                guard let self, let coordinator,
                      self.acceptsReviewAction(
                          for: handle,
                          coordinator: coordinator
                ) else { return }
                if let transaction {
                    coordinator.approveTransaction(
                        transaction,
                        reviewedNetwork: action.resolvedNetwork
                    )
                } else {
                    coordinator.reject()
                }
            }
            activeApproval(
                for: handle,
                coordinator: coordinator
            )?.beginReview()
        case .addEthereumChain(let action):
            presentAddEthereumChain(
                action,
                windowController: windowController,
                for: handle,
                coordinator: coordinator
            )
        }
        activateOldestPresentedApproval()
    }

    private func approvalWindow(
        peer: PeerMeta,
        for handle: ExtensionBridge.Handle,
        coordinator: NativeApprovalCoordinator
    ) -> WalletWindowController? {
        guard let approval = activeApproval(
            for: handle,
            coordinator: coordinator
        ) else { return nil }
        if let existing = approval.windowController as? WalletWindowController {
            existing.approvalPeer = peer
            return existing
        }
        let windowController = Window.showNew(
            closeOthers: false,
            approvalPeer: peer
        )
        approval.windowController = windowController
        return windowController
    }

    private func presentAddEthereumChain(
        _ action: AddEthereumChainAction,
        windowController: WalletWindowController,
        for handle: ExtensionBridge.Handle,
        coordinator: NativeApprovalCoordinator
    ) {
        guard activeApproval(
            for: handle,
            coordinator: coordinator
        ) != nil else { return }
        Self.installWaitingSurface(
            reason: Strings.loading,
            in: windowController
        )
        guard let window = windowController.window else {
            coordinator.reject()
            return
        }

        let alert = Alert()
        alert.messageText = Strings.addNetwork
        alert.informativeText =
            action.chainToAdd.chainName + "\n\n" +
            action.chainToAdd.defaultRpcUrl
        alert.alertStyle = .informational
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.cancel)
        alert.beginSheetModal(for: window) { [weak self, weak coordinator]
            response in
            guard let self, let coordinator else { return }
            Self.handleAddEthereumChainSheetResponse(
                response,
                isCurrentApproval: self.acceptsReviewAction(
                    for: handle,
                    coordinator: coordinator
                ),
                approve: coordinator.approveAddEthereumChain,
                reject: coordinator.reject
            )
        }
    }

    static func handleAddEthereumChainSheetResponse(
        _ response: NSApplication.ModalResponse,
        isCurrentApproval: Bool,
        approve: () -> Void,
        reject: () -> Void
    ) {
        guard isCurrentApproval else { return }
        if response == .alertFirstButtonReturn {
            approve()
        } else {
            reject()
        }
    }

    private func presentAccountSelection(
        _ action: SelectAccountAction,
        mode: NativeAccountSelectionMode,
        windowController: WalletWindowController,
        for handle: ExtensionBridge.Handle,
        coordinator: NativeApprovalCoordinator
    ) {
        let accountsList = instantiate(AccountsListViewController.self)
        let session = NativeAccountSelectionSession(
            action: action,
            mode: mode
        ) { [weak self, weak coordinator] accounts, network in
            guard let self, let coordinator,
                  self.acceptsReviewAction(
                      for: handle,
                      coordinator: coordinator
                  ) else { return }
            self.activeApproval(
                for: handle,
                coordinator: coordinator
            )?.disableRejectionOnWindowClose()
            self.showWaiting(for: handle, coordinator: coordinator)
            guard let accounts else {
                coordinator.reject()
                return
            }
            let ethereumNetwork = accounts.contains {
                $0.account.coin == .ethereum
            } ? network : nil
            coordinator.approveAccounts(
                accounts,
                ethereumNetwork: ethereumNetwork
            )
        }
        accountsList.accountSelection = session
        windowController.contentViewController = accountsList
        activeApproval(
            for: handle,
            coordinator: coordinator
        )?.beginReview {
            session.invalidate()
        }
    }

    private func showApprove(
        windowController: NSWindowController,
        transaction: Transaction,
        account: WalletAccount,
        walletId: String,
        chain: EthereumNetwork,
        completion: @escaping (Transaction?) -> Void
    ) {
        let controller = ApproveTransactionViewController.with(
            transaction: transaction,
            chain: chain,
            account: account,
            walletId: walletId,
            completion: completion
        )
        windowController.contentViewController = controller
    }

    private func showApprove(
        windowController: NSWindowController,
        browser: Browser?,
        subject: ApprovalSubject,
        meta: String,
        account: WalletAccount,
        walletId: String,
        solanaClusterSelection: SolanaClusterSelection?,
        completion: @escaping (Bool) -> Void
    ) {
        let window = windowController.window
        var authenticationContext: LAContext?
        var didResolveAuthentication = false
        let approveViewController = ApproveViewController.with(
            subject: subject,
            meta: meta,
            account: account,
            walletId: walletId,
            solanaClusterSelection: solanaClusterSelection
        ) { [weak self, weak window] approved in
            guard approved else {
                guard !didResolveAuthentication else { return }
                didResolveAuthentication = true
                completion(false)
                return
            }
            authenticationContext = self?.askAuthentication(
                on: window,
                getBackTo: window?.contentViewController,
                browser: browser,
                onStart: false,
                reason: subject.asAuthenticationReason,
                onWindowClose: {
                    didResolveAuthentication = true
                }
            ) { success in
                guard !didResolveAuthentication else { return }
                didResolveAuthentication = true
                authenticationContext = nil
                completion(success)
                if success {
                    (window?.contentViewController as? ApproveViewController)?
                        .enableWaiting()
                }
            }
        }
        approveViewController.localWindowCloseCompletion = {
            authenticationContext?.invalidate()
            authenticationContext = nil
            didResolveAuthentication = true
        }
        windowController.contentViewController = approveViewController
    }

    private func showWaiting(
        for handle: ExtensionBridge.Handle,
        coordinator: NativeApprovalCoordinator
    ) {
        guard let approval = activeApproval(
            for: handle,
            coordinator: coordinator
        ) else {
            return
        }
        let windowController: NSWindowController
        if let existing = approval.windowController {
            windowController = existing
        } else {
            windowController = Window.showNew(
                closeOthers: false,
                approvalPeer: coordinator.peer
            )
        }
        approval.endReview()
        approval.windowController = windowController
        Self.installWaitingSurface(
            reason: Strings.loading,
            in: windowController
        )
        activateOldestPresentedApproval()
    }

    private func showFailureSurface(
        for handle: ExtensionBridge.Handle,
        coordinator: NativeApprovalCoordinator
    ) {
        guard let approval = activeApproval(
            for: handle,
            coordinator: coordinator
        ) else { return }
        approval.endReview()
        if approval.windowController == nil {
            approval.windowController = Window.showNew(
                closeOthers: false,
                approvalPeer: coordinator.peer
            )
        }
        approval.windowController = Self.installFailureSurface(
            in: approval.windowController
        )
        activateOldestPresentedApproval()
    }

    @discardableResult
    static func installFailureSurface(
        in retainedWindowController: NSWindowController?
    ) -> NSWindowController {
        let windowController = retainedWindowController ??
            Window.showNew(closeOthers: false)
        Self.installWaitingSurface(
            reason: Strings.somethingWentWrong,
            in: windowController
        )
        return windowController
    }

    static func installWaitingSurface(
        reason: String,
        in windowController: NSWindowController
    ) {
        let outgoing = windowController.contentViewController
        if !(outgoing is WaitingViewController) {
            windowController.window?.delegate = nil
        }
        dismissApprovalSheets(in: windowController.window)
        if let waiting = outgoing as? WaitingViewController {
            waiting.update(reason: reason)
            return
        }
        windowController.contentViewController = WaitingViewController.with(
            reason: reason
        ) {
            Window.activateBrowser(specific: .safari)
        }
    }

    private func finishApproval(
        handle: ExtensionBridge.Handle,
        coordinator: NativeApprovalCoordinator
    ) {
        guard let approval = activeApproval(
            for: handle,
            coordinator: coordinator
        ) else { return }
        let window = approval.windowController?.window
        let windowNumber = window?.windowNumber
        let windowAction = Self.finishedApprovalWindowAction(
            windowNumber: windowNumber,
            isVisible: window?.isVisible == true,
            isMiniaturized: window?.isMiniaturized == true
        )
        approval.disableRejectionOnWindowClose()
        approval.endReview()
        removeActiveApproval(for: handle, coordinator: coordinator)
        window?.delegate = nil
        Self.dismissApprovalSheets(in: window)
        switch windowAction {
        case .none:
            activateOldestPresentedApproval()
        case .close:
            Window.closeWindow(idToClose: windowNumber)
            activateOldestPresentedApproval()
        case .closeAndActivate:
            Window.closeWindow(idToClose: windowNumber)
            if !activateOldestPresentedApproval() {
                Window.activateBrowser(specific: .safari)
            }
        }
    }

    private func discardApproval(
        handle: ExtensionBridge.Handle,
        coordinator: NativeApprovalCoordinator
    ) {
        guard let approval = activeApproval(
            for: handle,
            coordinator: coordinator
        ) else { return }
        let window = approval.windowController?.window
        let windowNumber = window?.windowNumber
        let shouldActivateAfterClose = window?.isVisible == true ||
            window?.isMiniaturized == true
        approval.disableRejectionOnWindowClose()
        approval.endReview()
        removeActiveApproval(for: handle, coordinator: coordinator)
        window?.delegate = nil
        Self.dismissApprovalSheets(in: window)
        Window.closeWindow(idToClose: windowNumber)
        if !activateOldestPresentedApproval(), shouldActivateAfterClose {
            Window.activateBrowser(specific: .safari)
        }
    }

    static func finishedApprovalWindowAction(
        windowNumber: Int?,
        isVisible: Bool,
        isMiniaturized: Bool
    ) -> FinishedApprovalWindowAction {
        guard windowNumber != nil else { return .none }
        return isVisible || isMiniaturized ? .closeAndActivate : .close
    }

    private func reactivateApprovalIfNeeded(for key: ApprovalRouteKey) {
        guard let approval = approvalInbox.active(for: key) else { return }
        if Self.shouldReactivateApproval(in: approval.coordinator.state) {
            activateOldestPresentedApproval()
        }
    }

    @discardableResult
    private func activateOldestPresentedApproval() -> Bool {
        guard let oldest = approvalInbox.oldestActive(where: { approval in
            guard approval.coordinator.state != .finished,
                  let window = approval.windowController?.window else {
                return false
            }
            return Window.isVisibleContentWindow(window)
        }) else { return false }
        oldest.value.activate()
        return true
    }

    private func activeApproval(
        for handle: ExtensionBridge.Handle,
        coordinator: NativeApprovalCoordinator
    ) -> ActiveApproval? {
        let key = ApprovalRouteKey(
            handle: handle,
            nativeDeliveryNonce: coordinator.nativeDeliveryNonce
        )
        guard let approval = approvalInbox.active(for: key),
              approval.coordinator === coordinator else { return nil }
        return approval
    }

    private func removeActiveApproval(
        for handle: ExtensionBridge.Handle,
        coordinator: NativeApprovalCoordinator
    ) {
        let key = ApprovalRouteKey(
            handle: handle,
            nativeDeliveryNonce: coordinator.nativeDeliveryNonce
        )
        guard approvalInbox.active(for: key)?.coordinator === coordinator else {
            return
        }
        approvalInbox.remove(key)
    }

    static func shouldReactivateApproval(
        in state: NativeApprovalCoordinator.State
    ) -> Bool {
        switch state {
        case .loading, .reviewing, .staging, .staged:
            return true
        case .rejecting, .finished:
            return false
        }
    }

    private func acceptsReviewAction(
        for handle: ExtensionBridge.Handle,
        coordinator: NativeApprovalCoordinator
    ) -> Bool {
        activeApproval(
            for: handle,
            coordinator: coordinator
        )?.acceptsReviewActions == true
    }

    static func dismissApprovalSheets(in window: NSWindow?) {
        guard let window else { return }
        for sheet in window.sheets {
            dismissApprovalSheets(in: sheet)
            window.endSheet(sheet, returnCode: .abort)
            sheet.orderOut(nil)
        }
    }

    static func rejectionHandler(
        for coordinator: NativeApprovalCoordinator
    ) -> () -> Void {
        return { [weak coordinator] in
            coordinator?.reject()
        }
    }

    @objc private func walletsChanged() {
        guard hasPassword,
              approvalInbox.hasAwaitingAuthentication ||
                pendingWalletOpenIntent.isPending else { return }
        resumePendingWork()
    }
}

enum DockAppLauncher {

    static func openDockApp(completion: @escaping (Bool) -> Void) {
        guard let dockAppURL else {
            completion(false)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(
            at: dockAppURL,
            configuration: configuration
        ) { application, error in
            DispatchQueue.main.async {
                completion(application != nil && error == nil)
            }
        }
    }

    private static var dockAppURL: URL? {
        guard Bundle.main.bundleIdentifier == Identifiers.macOSAmbientBundle
        else { return nil }

        guard let url = enclosingAppURL(
                  forHelperAt: Bundle.main.bundleURL
              ),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    static func enclosingAppURL(forHelperAt helperURL: URL) -> URL? {
        guard helperURL.isFileURL else { return nil }
        let helperURL = helperURL.standardizedFileURL
        guard helperURL.lastPathComponent == "Big Wallet.app" else {
            return nil
        }
        let helpersURL = helperURL.deletingLastPathComponent()
        let extensionContentsURL = helpersURL.deletingLastPathComponent()
        let extensionURL = extensionContentsURL.deletingLastPathComponent()
        let pluginsURL = extensionURL.deletingLastPathComponent()
        let appContentsURL = pluginsURL.deletingLastPathComponent()
        let appURL = appContentsURL.deletingLastPathComponent()
        guard helpersURL.lastPathComponent == "Helpers",
              extensionContentsURL.lastPathComponent == "Contents",
              extensionURL.pathExtension == "appex",
              pluginsURL.lastPathComponent == "PlugIns",
              appContentsURL.lastPathComponent == "Contents",
              appURL.pathExtension == "app" else { return nil }
        return appURL
    }
}
