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
    private var isReady = false
    private let credentialDependencies: StartupCredentialCoordinator.Dependencies
    private lazy var startupCredentials = StartupCredentialCoordinator(
        dependencies: credentialDependencies
    ) { [weak self] event in
        guard let self else { return }
        switch event {
        case .authenticated:
            activateAwaitingApprovals()
            if pendingWalletOpenIntent.consume() { showWallet() }
        case .cancelled:
            pendingWalletOpenIntent.cancel()
            cancelPendingApprovals()
        case .setupRequiredInDockApp:
            cancelPendingApprovals()
        case .handedOff:
            pendingWalletOpenIntent.cancel()
        }
    }
    private var walletWindowController: NSWindowController?
    private var pendingWalletOpenIntent = PendingWalletOpenIntent()
    private var nativeDeliveryOwner: ExtensionBridge.NativeDeliveryOwner?
    private var approvalInbox = ApprovalInbox<ActiveApproval>()

    private override init() {
        credentialDependencies = .init()
        super.init()
    }

    init(
        approvalInbox: ApprovalInbox<ActiveApproval>,
        credentialDependencies: StartupCredentialCoordinator.Dependencies = .init()
    ) {
        self.approvalInbox = approvalInbox
        self.credentialDependencies = credentialDependencies
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
    }

    private func resumePendingWork() {
        guard isReady else { return }
        startPendingApprovals()
        guard pendingWalletOpenIntent.isPending || approvalInbox.hasAwaitingAuthentication else { return }
        startupCredentials.requestAccess()
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
        resumePendingWork()
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
        startupCredentials.refresh()
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
        let finishedWindowAction = approval.present(snapshot.presentation)
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


}

extension Agent.ActiveApproval {

    fileprivate func present(
        _ presentation: NativeApprovalCoordinator.Presentation
    ) -> Agent.FinishedApprovalWindowAction? {
        switch presentation {
        case .approval(let request, let action):
            present(action: action, peer: request.peerMeta)
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

    private func present(action: DappRequestAction, peer: PeerMeta) {
        guard let review = beginReview() else { return }
        let windowController = approvalWindow(peer: peer)
        switch action {
        case .selectAccount(let action):
            presentAccountSelection(action, mode: .selectAccount, review: review)
        case .switchAccount(let action):
            presentAccountSelection(action, mode: .switchAccount, review: review)
        case .approveMessage(let action):
            showApproveMessage(action, review: review)
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
        review: NativeApprovalReviewLifetime
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
        ) { [weak self, weak window] decision in
            guard let self, acceptsActions(for: review) else { return }
            guard case .approved = decision else {
                guard !didResolveAuthentication else { return }
                didResolveAuthentication = true
                coordinator.reject()
                return
            }
            guard let window else {
                coordinator.reject()
                return
            }
            authenticationTask?.cancel()
            authenticationTask = Task { [weak self, weak window] in
                let success = await Window.authenticate(
                    in: window,
                    reason: action.subject.asAuthenticationReason,
                    reviewLifetime: review
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
