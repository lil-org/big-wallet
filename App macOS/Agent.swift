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

    @MainActor
    final class ActiveApproval {
        let coordinator: NativeApprovalCoordinator
        private lazy var windowCloseObserver = NativeApprovalWindowCloseObserver { [weak self] in
            guard let self else { return }
            isDismissed = true
            coordinator.reject()
        }
        private(set) var isDismissed = false
        var pendingPresentation: NativeApprovalCoordinator.Presentation?
        private var sharedReviewCleanup: (() -> Void)?
        private(set) var acceptsReviewActions = false
        var windowController: NSWindowController? {
            didSet {
                if let window = windowController?.window {
                    windowCloseObserver.observe(window)
                }
            }
        }

        init(coordinator: NativeApprovalCoordinator) {
            self.coordinator = coordinator

        }

        func activate() {
            guard let windowController,
                  windowController.window != nil else {
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            Window.reactivateWindow(windowController)
        }

        func restorePresentation() {
            isDismissed = false
        }

        func receive(_ presentation: NativeApprovalCoordinator.Presentation) -> Bool {
            guard isDismissed else { return true }
            switch presentation {
            case .finished, .superseded: return true
            default:
                pendingPresentation = presentation
                return false
            }
        }

        func beginReview(
            sharedCleanup: (() -> Void)? = nil
        ) {
            acceptsReviewActions = true
            sharedReviewCleanup = sharedCleanup
        }

        func endReview() {
            acceptsReviewActions = false
            sharedReviewCleanup?()
            sharedReviewCleanup = nil
            (windowController?.contentViewController as?
                NativeApprovalReviewTeardown)?
                .invalidateNativeApprovalReview()
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
    private var nativeDeliveryOwner: ExtensionBridge.NativeDeliveryOwner?
    private var approvalInbox = ApprovalInbox<ActiveApproval>()

    private override init() {
        super.init()
    }

    init(approvalInbox: ApprovalInbox<ActiveApproval>) {
        self.approvalInbox = approvalInbox
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
        for coordinator in approvalInbox.coordinators { coordinator.expireIfDormant() }
        for coordinator in approvalInbox.dormantCoordinators { coordinator.retryRecovery() }
        switch route {
        case .approval(_, let handle, let nativeDeliveryNonce):
            let key = ApprovalRouteKey(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce
            )
            if let existing = approvalInbox.coordinator(for: key) {
                if existing.isAwaitingAuthentication {
                    resumePendingWork()
                    startupAuthenticationPresentation.reactivateWindow()
                } else {
                    reactivateApprovalIfNeeded(for: key)
                }
                return
            }
            let coordinator = NativeApprovalCoordinator(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce
            )
            guard approvalInbox.register(coordinator) else { return }
            restoreOldestRecoverableApproval()
            coordinator.onEvent = { [weak self, weak coordinator] event in
                guard let self, let coordinator,
                      self.approvalInbox.coordinator(for: key) === coordinator else {
                    return
                }
                switch event {
                case .authenticationRequired:
                    self.handleReceiptOwnedApproval(key)
                case .presentation(let presentation):
                    if self.approvalInbox.active(for: key) == nil {
                        if case .finished = presentation {
                            self.approvalInbox.remove(key)
                        } else if case .superseded = presentation {
                            self.approvalInbox.remove(key)
                        }
                        return
                    }
                    self.present(presentation, for: handle, coordinator: coordinator)
                }
            }
            startPendingApprovals()
        case .showWallet:
            open()
        }
    }

    func open() {
        start(openOnLaunch: false)
        for coordinator in approvalInbox.coordinators { coordinator.expireIfDormant() }
        for coordinator in approvalInbox.dormantCoordinators { coordinator.retryRecovery() }
        restoreOldestRecoverableApproval()
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
        startPendingApprovals()

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
        
    private func startPendingApprovals() {
        guard isReady,
              let nativeDeliveryOwner else { return }
        for coordinator in approvalInbox.coordinators {
            coordinator.start(
                nativeDeliveryOwner: nativeDeliveryOwner
            )
        }
    }

    private func handleReceiptOwnedApproval(_ key: ApprovalRouteKey) {
        guard let coordinator = approvalInbox.coordinator(for: key),
              coordinator.isAwaitingAuthentication else { return }
        guard hasPassword else {
            switch Self.missingPasswordApprovalAction(
                canCreatePassword: CurrentApp.canCreatePassword
            ) {
            case .awaitOnboarding:
                resumePendingWork()
            case .rejectAndOpenDock:
                coordinator.cancelBeforeAuthentication()
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
        for coordinator in approvalInbox.coordinators {
            coordinator.cancelBeforeAuthentication()
        }
    }

    func applicationDidBecomeActive() {
        guard approvalInbox.hasAwaitingAuthentication else { return }
        resumePendingWork()
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
        guard let coordinator = approvalInbox.coordinator(for: key),
              coordinator.isAwaitingAuthentication else { return }
        let approval = ActiveApproval(coordinator: coordinator)
        guard approvalInbox.activate(approval, for: key) else { return }
        coordinator.resumeAfterAuthentication()
    }

    func present(
        _ presentation: NativeApprovalCoordinator.Presentation,
        for handle: ExtensionBridge.Handle,
        coordinator: NativeApprovalCoordinator
    ) {
        guard activeApproval(for: handle, coordinator: coordinator)?.receive(presentation) != false else {
            return
        }
        switch presentation {
        case .approval(let request, let action):
            present(
                action: action,
                peer: request.peerMeta,
                for: handle,
                coordinator: coordinator
            )
        case .waiting:
            showWaiting(for: handle, coordinator: coordinator)
        case .retryRequired:
            showFailureSurface(for: handle, coordinator: coordinator, retry: true)
        case .rejecting:
            showFailureSurface(for: handle, coordinator: coordinator)
        case .finished, .superseded:
            closeApproval(handle: handle, coordinator: coordinator)
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
                solanaClusterOptions: action.solanaClusterOptions
            ) { [weak self, weak coordinator] decision in
                guard let self, let coordinator,
                      self.acceptsReviewAction(
                          for: handle,
                          coordinator: coordinator
                      ) else { return }
                switch decision {
                case .approved(let cluster):
                    coordinator.approveMessage(solanaCluster: cluster)
                case .rejected:
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
        guard let approval = activeApproval(
            for: handle,
            coordinator: coordinator
        ) else { return }
        approval.beginReview()
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
        solanaClusterOptions: SolanaClusterOptions?,
        completion: @escaping (ApproveViewController.Decision) -> Void
    ) {
        let window = windowController.window
        var authenticationContext: LAContext?
        var didResolveAuthentication = false
        let approveViewController = ApproveViewController.with(
            subject: subject,
            meta: meta,
            account: account,
            walletId: walletId,
            solanaClusterOptions: solanaClusterOptions
        ) { [weak self, weak window] decision in
            guard case .approved = decision else {
                guard !didResolveAuthentication else { return }
                didResolveAuthentication = true
                completion(.rejected)
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
                completion(success ? decision : .rejected)
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
        coordinator: NativeApprovalCoordinator,
        retry: Bool = false
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
            in: approval.windowController,
            retryAction: retry ? { [weak coordinator] in coordinator?.retryRecovery() } : nil
        )
        activateOldestPresentedApproval()
    }

    @discardableResult
    static func installFailureSurface(
        in retainedWindowController: NSWindowController?,
        retryAction: (() -> Void)? = nil
    ) -> NSWindowController {
        let windowController = retainedWindowController ??
            Window.showNew(closeOthers: false)
        Self.installWaitingSurface(
            reason: Strings.somethingWentWrong,
            in: windowController,
            retryAction: retryAction
        )
        return windowController
    }

    static func installWaitingSurface(
        reason: String,
        in windowController: NSWindowController,
        retryAction: (() -> Void)? = nil
    ) {
        let outgoing = windowController.contentViewController
        if !(outgoing is WaitingViewController) {
            windowController.window?.delegate = nil
        }
        dismissApprovalSheets(in: windowController.window)
        if let waiting = outgoing as? WaitingViewController {
            waiting.update(reason: reason, retryAction: retryAction)
            return
        }
        windowController.contentViewController = WaitingViewController.with(
            reason: reason,
            retryAction: retryAction
        ) {
            Window.activateBrowser(specific: .safari)
        }
    }

    private func closeApproval(
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
        restorePresentation(for: key, approval: approval, retryPaused: true)
    }

    private func restorePresentation(
        for key: ApprovalRouteKey,
        approval: ActiveApproval,
        retryPaused: Bool
    ) {
        guard approval.coordinator.canReactivate else { return }
        approval.restorePresentation()
        if approval.coordinator.isPaused {
            approval.pendingPresentation = nil
            if retryPaused {
                approval.coordinator.retryRecovery()
            } else {
                present(.retryRequired, for: key.handle, coordinator: approval.coordinator)
            }
        } else if let pending = approval.pendingPresentation {
            approval.pendingPresentation = nil
            present(pending, for: key.handle, coordinator: approval.coordinator)
        } else if !approval.acceptsReviewActions {
            showWaiting(for: key.handle, coordinator: approval.coordinator)
        }
        approval.activate()
    }

    @discardableResult
    private func activateOldestPresentedApproval() -> Bool {
        guard let oldest = approvalInbox.oldestActive(where: { approval in
            guard !approval.coordinator.isFinished,
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

    func restoreOldestRecoverableApproval() {
        guard let oldest = approvalInbox.oldestActive(where: {
            $0.coordinator.canReactivate && ($0.coordinator.isPaused || $0.isDismissed)
        }) else { return }
        restorePresentation(for: oldest.key, approval: oldest.value, retryPaused: false)
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
