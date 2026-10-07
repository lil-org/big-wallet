// ∅ 2026 lil org

import Cocoa

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

    isolated deinit {
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

        init(_ value: NSViewController? = nil) {
            self.value = value
        }

        func reactivateWindow() {
            guard let value,
                  let window = value.viewIfLoaded?.window,
                  window.contentViewController === value else { return }
            window.deminiaturize(nil)
            Window.activateWindow(window)
        }
    }

    @MainActor
    private final class WeakWindowReference {
        weak var value: NSWindow?

        init(_ value: NSWindow?) {
            self.value = value
        }
    }

    enum LocalAuthenticationResolution: Equatable {
        case authenticated
        case showPassword
        case failed
    }

    enum AuthenticationContext: Sendable {
        case startup
        case walletManagement(returningTo: WeakViewControllerReference)
        case approval(returningTo: WeakViewControllerReference, lifetime: NativeApprovalReviewLifetime)
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
            endReview()
            coordinator.reject()
        }
        private(set) var isDismissed = false
        private var lastRenderedRevision: UInt64?
        private(set) var currentReview: NativeApprovalReviewLifetime?
        private var isRetired = false
        var windowController: NSWindowController? {
            didSet {
                guard !isRetired else { return }
                if let window = windowController?.window {
                    windowCloseObserver.observe(window)
                }
            }
        }

        init(coordinator: NativeApprovalCoordinator) {
            self.coordinator = coordinator
        }

        var acceptsReviewActions: Bool {
            currentReview?.isActive == true
        }

        private func acceptsActions(for review: NativeApprovalReviewLifetime) -> Bool {
            currentReview === review && review.isActive
        }

        func activate() {
            guard !isRetired else { return }
            guard let windowController,
                  windowController.window != nil else {
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            Window.reactivateWindow(windowController)
        }

        func restorePresentation() {
            guard !isRetired else { return }
            isDismissed = false
        }

        func beginRenderingCurrentPresentation(
            allowNewWaitingWindow: Bool = false
        ) -> NativeApprovalCoordinator.PresentationSnapshot? {
            guard !isRetired,
                  let snapshot = coordinator.currentPresentation,
                  snapshot.revision != lastRenderedRevision,
                  !isDismissed || snapshot.presentation.isTerminal else { return nil }
            if case .waiting = snapshot.presentation,
               windowController == nil, !allowNewWaitingWindow { return nil }
            lastRenderedRevision = snapshot.revision
            return snapshot
        }

        @discardableResult
        func beginReview() -> NativeApprovalReviewLifetime? {
            guard !isRetired else { return nil }
            endReview()
            guard !isRetired else { return nil }
            let review = NativeApprovalReviewLifetime()
            currentReview = review
            return review
        }

        func endReview() {
            finishReview(retiring: false)
        }

        private func finishReview(retiring: Bool) {
            guard !isRetired else { return }
            let review = currentReview
            currentReview = nil
            isRetired = retiring
            if retiring {
                windowCloseObserver.disable()
            }
            review?.invalidate()
        }
    }

    static let shared = Agent()
    var keychain = Keychain.shared
    private var didStart = false
    private var isReady = false
    private var didEnterPasswordOnStart = false
    private var isAuthenticatingOnStart = false
    private var startupAuthentication: Task<Void, Never>?
    private var onboardingTask: Task<Void, Never>?
    private let startupAuthenticationPresentation = WeakViewControllerReference()
    private var welcomeWindowController: NSWindowController?
    private var welcomeWindowCloseObserver: NativeApprovalWindowCloseObserver?
    private var walletWindowController: NSWindowController?
    private var passwordUnavailableWindowController: NSWindowController?
    private var isPresentingCredentialWindow = false
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
                case .presentationChanged:
                    if self.approvalInbox.active(for: key) == nil {
                        if coordinator.currentPresentation?.presentation.isTerminal == true {
                            self.approvalInbox.remove(key)
                        }
                        return
                    }
                    self.renderCurrentPresentation(for: handle, coordinator: coordinator)
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
        guard pendingWalletOpenIntent.isPending || approvalInbox.hasAwaitingAuthentication,
              let passwordState = passwordStateForPendingWork() else { return }
        guard passwordState == .present else {
            if CurrentApp.canCreatePassword {
                showWelcomeIfNeeded()
            } else {
                requestDockOnboarding()
            }
            return
        }

        if welcomeWindowController != nil {
            didEnterPasswordOnStart = false
            clearWelcomeWindowOwnership()
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
        startupAuthentication = Task { [weak self] in
            guard let self else { return }
            let success = await askAuthentication(for: .startup, reason: .start)
            guard !Task.isCancelled else { return }
            isAuthenticatingOnStart = false
            startupAuthenticationPresentation.value = nil
            guard success else {
                cancelCredentialPresentation()
                return
            }
            guard let passwordState = passwordStateForPendingWork() else { return }
            guard passwordState == .present else {
                resumePendingWork()
                return
            }
            didEnterPasswordOnStart = true
            resumePendingWork()
        }
    }

    func askAuthentication(for authentication: AuthenticationContext, reason: AuthenticationReason) async -> Bool {
        let returningController: WeakViewControllerReference?
        let reviewLifetime: NativeApprovalReviewLifetime?
        switch authentication {
        case .startup:
            returningController = nil
            reviewLifetime = nil
        case .walletManagement(let controller):
            returningController = controller
            reviewLifetime = nil
        case .approval(let controller, let lifetime):
            returningController = controller
            reviewLifetime = lifetime
        }
        guard !Task.isCancelled, reviewLifetime?.isActive != false else { return false }
        let onStart = returningController == nil
        let originalWindow = WeakWindowReference(returningController?.value?.viewIfLoaded?.window)
        guard onStart || returningController?.value != nil else { return false }

        func showPasswordScreen() async -> Bool {
            guard !Task.isCancelled, reviewLifetime?.isActive != false else { return false }
            let response = AuthenticationResponse()
            return await response.wait { response in
                let wasPresenting = isPresentingCredentialWindow
                if onStart {
                    isPresentingCredentialWindow = true
                    dismissPasswordUnavailableWindow()
                }
                defer { isPresentingCredentialWindow = wasPresenting }
                let existingWindow = originalWindow.value
                let window = existingWindow ?? Window.showNew(closeOthers: onStart).window
                guard !Task.isCancelled, reviewLifetime?.isActive != false else {
                    if existingWindow == nil { window?.close() }
                    response.resolve(false)
                    return
                }
                let presentation = WeakViewControllerReference()
                let passwordViewController = PasswordViewController.with(mode: .enter, reason: reason, reviewLifetime: reviewLifetime) { [weak window] success in
                    guard reviewLifetime?.isActive != false,
                          window?.contentViewController === presentation.value else {
                        response.resolve(false)
                        return
                    }
                    if let returningController = returningController?.value {
                        window?.contentViewController = returningController
                    } else {
                        Window.closeWindow(idToClose: window?.windowNumber)
                    }
                    response.resolve(success)
                }
                passwordViewController.keychain = keychain
                passwordViewController.retainedReturnController = returningController?.value
                presentation.value = passwordViewController
                window?.contentViewController = passwordViewController
                if onStart { startupAuthenticationPresentation.value = passwordViewController }
            }
        }

        guard let outcome = await attemptDeviceAuthentication(reason: reason.title) else {
            return await showPasswordScreen()
        }
        guard !Task.isCancelled, reviewLifetime?.isActive != false else { return false }
        switch Self.localAuthenticationResolution(success: outcome == .succeeded, onStart: onStart) {
        case .authenticated: return true
        case .showPassword: return await showPasswordScreen()
        case .failed: return false
        }
    }

    func attemptDeviceAuthentication(reason: String) async -> DeviceAuthentication.Outcome? {
        guard DeviceAuthentication.canUseBiometrics else { return nil }
        return await DeviceAuthentication.attemptBiometrics(reason: reason)
    }

    @MainActor
    private final class AuthenticationResponse {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        func wait(_ present: (AuthenticationResponse) -> Void) async -> Bool {
            guard !Task.isCancelled else { return false }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if let result {
                        continuation.resume(returning: result)
                    } else {
                        self.continuation = continuation
                        present(self)
                    }
                }
            } onCancel: {
                Task { @MainActor in self.resolve(false) }
            }
        }

        func resolve(_ result: Bool) {
            guard self.result == nil else { return }
            self.result = result
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(returning: result)
        }
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
        guard let passwordState = passwordStateForPendingWork() else { return }
        guard passwordState == .present else {
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
        guard pendingWalletOpenIntent.isPending || approvalInbox.hasAwaitingAuthentication else { return }
        resumePendingWork()
    }

    private func passwordStateForPendingWork() -> Keychain.PasswordState? {
        do {
            let state = try keychain.passwordState()
            dismissPasswordUnavailableWindow()
            return state
        } catch {
            showPasswordUnavailableWindow()
            return nil
        }
    }

    private func showPasswordUnavailableWindow() {
        guard !isPresentingCredentialWindow else { return }
        if let controller = passwordUnavailableWindowController,
           let window = controller.window, Window.isVisibleContentWindow(window) {
            return
        }
        isPresentingCredentialWindow = true
        defer { isPresentingCredentialWindow = false }
        let controller = Window.showNew(closeOthers: false)
        passwordUnavailableWindowController = controller
        controller.contentViewController = WaitingViewController.with(
            reason: Strings.failedToLoad,
            isWorking: false,
            retryAction: { [weak self] in self?.resumePendingWork() }
        ) { [weak self, weak controller] in
            guard let self, let controller,
                  passwordUnavailableWindowController === controller else { return }
            passwordUnavailableWindowController = nil
            cancelCredentialPresentation()
        }
    }

    private func cancelCredentialPresentation() {
        let setupWindow = welcomeWindowController
        let authenticationPresentation = startupAuthenticationPresentation.value
        let authenticationWindow = authenticationPresentation?.viewIfLoaded?.window
        pendingWalletOpenIntent.cancel()
        clearWelcomeWindowOwnership()
        startupAuthentication?.cancel()
        startupAuthentication = nil
        isAuthenticatingOnStart = false
        startupAuthenticationPresentation.value = nil
        cancelPendingApprovals()
        dismissPasswordUnavailableWindow()
        setupWindow?.close()
        if authenticationWindow?.contentViewController === authenticationPresentation {
            authenticationWindow?.close()
        }
    }

    private func dismissPasswordUnavailableWindow() {
        guard let controller = passwordUnavailableWindowController else { return }
        passwordUnavailableWindowController = nil
        controller.window?.delegate = nil
        controller.close()
    }

    private func requestDockOnboarding() {
        guard dockOnboardingHandoff.begin() else { return }
        onboardingTask = Task { [weak self] in
            let succeeded = await DockAppLauncher.openDockApp()
            guard let self, !Task.isCancelled,
                  dockOnboardingHandoff.finish(succeeded: succeeded) else { return }
            pendingWalletOpenIntent.cancel()
        }
    }

    private func showWelcomeIfNeeded() {
        guard !isPresentingCredentialWindow else { return }
        if let windowController = welcomeWindowController,
           let window = windowController.window,
           Window.isVisibleContentWindow(window) {
            window.deminiaturize(nil)
            Window.activateWindow(window)
            return
        }
        isPresentingCredentialWindow = true
        defer { isPresentingCredentialWindow = false }
        clearWelcomeWindowOwnership()
        let windowController = Window.showNew(closeOthers: true)
        welcomeWindowController = windowController
        let cancelOnboarding: () -> Void = {
            [weak self, weak windowController] in
            self?.cancelWelcomeWindow(matching: windowController)
        }
        let closeObserver = NativeApprovalWindowCloseObserver(onClose: cancelOnboarding)
        welcomeWindowCloseObserver = closeObserver
        if let window = windowController.window {
            closeObserver.observe(window)
        }
        let welcomeViewController = WelcomeViewController.new(onboardingCancelled: cancelOnboarding) {
            [weak self, weak windowController] createdPassword in
            guard let self, let windowController,
                  self.welcomeWindowController === windowController else { return }
            self.clearWelcomeWindowOwnership(matching: windowController)
            if createdPassword {
                self.didEnterPasswordOnStart = true
            } else {
                self.didEnterPasswordOnStart = false
            }
            self.resumePendingWork()
        }
        welcomeViewController.keychain = keychain
        windowController.contentViewController = welcomeViewController
    }

    private func cancelWelcomeWindow(matching windowController: NSWindowController?) {
        guard let windowController, welcomeWindowController === windowController else { return }
        clearWelcomeWindowOwnership(matching: windowController)
        cancelCredentialPresentation()
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

    func renderCurrentPresentation(
        for handle: ExtensionBridge.Handle,
        coordinator: NativeApprovalCoordinator,
        allowNewWaitingWindow: Bool = false
    ) {
        guard let approval = activeApproval(for: handle, coordinator: coordinator),
              let snapshot = approval.beginRenderingCurrentPresentation(
                  allowNewWaitingWindow: allowNewWaitingWindow
              ) else { return }
        let finishedWindowAction = approval.present(snapshot.presentation, using: self)
        if finishedWindowAction != nil {
            approvalInbox.remove(ApprovalRouteKey(
                handle: handle,
                nativeDeliveryNonce: coordinator.nativeDeliveryNonce
            ))
        }
        if case .rejecting = snapshot.presentation { return }
        if !activateOldestPresentedApproval(), finishedWindowAction == .closeAndActivate {
            Window.activateBrowser(specific: .safari)
        }
    }

    private func reactivateApprovalIfNeeded(for key: ApprovalRouteKey) {
        approvalInbox.active(for: key)?.restorePresentation(retryPaused: true, using: self)
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

    func restoreOldestRecoverableApproval() {
        guard let oldest = approvalInbox.oldestActive(where: {
            $0.coordinator.canReactivate && ($0.coordinator.isPaused || $0.isDismissed)
        }) else { return }
        oldest.value.restorePresentation(retryPaused: false, using: self)
    }

    @objc private func walletsChanged() {
        guard approvalInbox.hasAwaitingAuthentication ||
                pendingWalletOpenIntent.isPending else { return }
        resumePendingWork()
    }
}

extension Agent.ActiveApproval {

    fileprivate func present(
        _ presentation: NativeApprovalCoordinator.Presentation,
        using agent: Agent
    ) -> Agent.FinishedApprovalWindowAction? {
        switch presentation {
        case .approval(let request, let action):
            present(action: action, peer: request.peerMeta, using: agent)
        case .waiting:
            showWaiting()
        case .retryRequired:
            showFailureSurface(retry: true)
        case .rejecting:
            showFailureSurface()
        case .interrupted:
            if isDismissed { return close() }
            showFailureSurface(reason: Strings.approvalInterrupted)
            finishReview(retiring: true)
            return Agent.FinishedApprovalWindowAction.none
        case .finished, .superseded:
            return close()
        }
        return nil
    }

    private func present(action: DappRequestAction, peer: PeerMeta, using agent: Agent) {
        guard let review = beginReview() else { return }
        let windowController = approvalWindow(peer: peer)
        switch action {
        case .selectAccount(let action):
            presentAccountSelection(action, mode: .selectAccount, review: review)
        case .switchAccount(let action):
            presentAccountSelection(action, mode: .switchAccount, review: review)
        case .approveMessage(let action):
            showApproveMessage(action, review: review, using: agent)
        case .approveTransaction(let action):
            windowController.contentViewController = ApproveTransactionViewController.with(
                transaction: action.transaction,
                chain: action.chain,
                account: action.account,
                walletId: action.walletId,
                reviewLifetime: review
            ) { [weak self] transaction in
                guard let self, acceptsActions(for: review) else { return }
                if let transaction {
                    coordinator.approveTransaction(
                        transaction,
                        reviewedNetwork: action.resolvedNetwork
                    )
                } else {
                    coordinator.reject()
                }
            }
        case .addEthereumChain(let action):
            presentAddEthereumChain(action, review: review)
        }
    }

    private func approvalWindow(peer: PeerMeta? = nil) -> NSWindowController {
        if let windowController {
            if let peer {
                (windowController as? WalletWindowController)?.approvalPeer = peer
            }
            return windowController
        }
        let controller = Window.showNew(
            closeOthers: false,
            approvalPeer: peer ?? coordinator.peer
        )
        windowController = controller
        return controller
    }

    private func presentAddEthereumChain(
        _ action: AddEthereumChainAction,
        review: NativeApprovalReviewLifetime
    ) {
        let controller = approvalWindow()
        Self.installWaitingSurface(reason: Strings.loading, in: controller)
        guard let window = controller.window else {
            coordinator.reject()
            return
        }
        let alert = Alert()
        alert.messageText = Strings.addNetwork
        alert.informativeText = action.chainToAdd.chainName + "\n\n" + action.chainToAdd.defaultRpcUrl
        alert.alertStyle = .informational
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.cancel)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, acceptsActions(for: review) else { return }
            if response == .alertFirstButtonReturn {
                coordinator.approveAddEthereumChain()
            } else {
                coordinator.reject()
            }
        }
    }

    private func presentAccountSelection(
        _ action: SelectAccountAction,
        mode: NativeAccountSelectionMode,
        review: NativeApprovalReviewLifetime
    ) {
        let accountsList = instantiate(AccountsListViewController.self)
        let session = NativeAccountSelectionSession(action: action, mode: mode, lifetime: review) {
            [weak self] accounts, network in
            guard let self, acceptsActions(for: review) else { return }
            guard let accounts else {
                coordinator.reject()
                return
            }
            let ethereumNetwork = accounts.contains {
                $0.account.coin == .ethereum
            } ? network : nil
            coordinator.approveAccounts(accounts, ethereumNetwork: ethereumNetwork)
        }
        accountsList.accountSelection = session
        approvalWindow().contentViewController = accountsList
    }

    private func showApproveMessage(
        _ action: SignMessageAction,
        review: NativeApprovalReviewLifetime,
        using agent: Agent
    ) {
        let controller = approvalWindow()
        let window = controller.window
        var authenticationTask: Task<Void, Never>?
        var didResolveAuthentication = false
        let approveViewController = ApproveViewController.with(
            subject: action.subject,
            meta: action.meta,
            account: action.account,
            walletId: action.walletId,
            solanaClusterOptions: action.solanaClusterOptions,
            reviewLifetime: review
        ) { [weak self, weak agent, weak window] decision in
            guard let self, acceptsActions(for: review) else { return }
            guard case .approved = decision else {
                guard !didResolveAuthentication else { return }
                didResolveAuthentication = true
                coordinator.reject()
                return
            }
            guard let returningController = window?.contentViewController else {
                coordinator.reject()
                return
            }
            let authentication = Agent.AuthenticationContext.approval(returningTo: .init(returningController), lifetime: review)
            authenticationTask?.cancel()
            authenticationTask = Task { [weak self, weak window, weak agent] in
                guard let agent else { return }
                let success = await agent.askAuthentication(
                    for: authentication,
                    reason: action.subject.asAuthenticationReason
                )
                guard let self, !Task.isCancelled, acceptsActions(for: review), !didResolveAuthentication else { return }
                didResolveAuthentication = true
                authenticationTask = nil
                if success, case .approved(let cluster) = decision {
                    coordinator.approveMessage(solanaCluster: cluster)
                    (window?.contentViewController as? ApproveViewController)?.enableWaiting()
                } else {
                    coordinator.reject()
                }
            }
        }
        approveViewController.localWindowCloseCompletion = {
            authenticationTask?.cancel()
            authenticationTask = nil
            didResolveAuthentication = true
        }
        controller.contentViewController = approveViewController
    }

    private func showWaiting() {
        let controller = approvalWindow()
        endReview()
        Self.installWaitingSurface(reason: Strings.loading, in: controller)
    }

    private func showFailureSurface(retry: Bool = false, reason: String = Strings.somethingWentWrong) {
        endReview()
        Self.installWaitingSurface(
            reason: reason,
            in: approvalWindow(),
            isWorking: false,
            retryAction: retry ? { [weak self] in
                guard let self, !isRetired else { return }
                coordinator.retryRecovery()
            } : nil
        )
    }

    private static func installWaitingSurface(
        reason: String,
        in windowController: NSWindowController,
        isWorking: Bool = true,
        retryAction: (() -> Void)? = nil
    ) {
        let outgoing = windowController.contentViewController
        if !(outgoing is WaitingViewController) {
            windowController.window?.delegate = nil
        }
        dismissApprovalSheets(in: windowController.window)
        if let waiting = outgoing as? WaitingViewController {
            waiting.update(reason: reason, isWorking: isWorking, retryAction: retryAction)
            return
        }
        windowController.contentViewController = WaitingViewController.with(
            reason: reason,
            isWorking: isWorking,
            retryAction: retryAction
        ) {
            Window.activateBrowser(specific: .safari)
        }
    }

    @discardableResult
    func close() -> Agent.FinishedApprovalWindowAction {
        guard !isRetired else { return .none }
        let window = windowController?.window
        let action = Self.finishedApprovalWindowAction(
            windowNumber: window?.windowNumber,
            isVisible: window?.isVisible == true,
            isMiniaturized: window?.isMiniaturized == true
        )
        finishReview(retiring: true)
        window?.delegate = nil
        Self.dismissApprovalSheets(in: window)
        if action != .none {
            Window.closeWindow(idToClose: window?.windowNumber)
        }
        return action
    }

    static func finishedApprovalWindowAction(
        windowNumber: Int?,
        isVisible: Bool,
        isMiniaturized: Bool
    ) -> Agent.FinishedApprovalWindowAction {
        guard windowNumber != nil else { return .none }
        return isVisible || isMiniaturized ? .closeAndActivate : .close
    }

    fileprivate func restorePresentation(retryPaused: Bool, using agent: Agent) {
        guard !isRetired, coordinator.canReactivate else { return }
        restorePresentation()
        if coordinator.isPaused && retryPaused && !coordinator.requiresExplicitReviewRetry {
            coordinator.retryRecovery()
        }
        agent.renderCurrentPresentation(
            for: coordinator.handle,
            coordinator: coordinator,
            allowNewWaitingWindow: true
        )
        activate()
    }

    private static func dismissApprovalSheets(in window: NSWindow?) {
        guard let window else { return }
        for sheet in window.sheets {
            dismissApprovalSheets(in: sheet)
            window.endSheet(sheet, returnCode: .abort)
            sheet.orderOut(nil)
        }
    }
}

@MainActor
enum DockAppLauncher {

    static func openDockApp() async -> Bool {
        guard let dockAppURL, !Task.isCancelled else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.allowsRunningApplicationSubstitution = false
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: dockAppURL, configuration: configuration) { application, error in
                continuation.resume(returning: application != nil && error == nil)
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
