import WalletFlows
import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Cocoa
#if BW_SAFARI_VM_TESTING
import SafariServices
#endif

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
class Agent: NSObject, WalletAccessObserver {
    
    enum FinishedApprovalWindowAction: Equatable {
        case none
        case close
        case closeAndActivate
    }

    @MainActor
    final class ActiveApproval {
        let coordinator: NativeApprovalCoordinator
        let walletAccess: NativeWalletAccess
        private let unlockWallet: () -> Void
        private lazy var windowCloseObserver = NativeApprovalWindowCloseObserver { [weak self] in
            guard let self else { return }
            isDismissed = true
            coordinator.reject()
        }
        private(set) var isDismissed = false
        private var lastRenderedRevision: UInt64?
        private(set) var isRetired = false
        var windowController: NSWindowController? {
            didSet {
                guard !isRetired else { return }
                if let window = windowController?.window {
#if BW_SAFARI_VM_TESTING
                    window.setAccessibilityIdentifier("safari.approval.window.\(UUID().uuidString)")
#endif
                    windowCloseObserver.observe(window)
                }
            }
        }

        init(coordinator: NativeApprovalCoordinator, access: WalletAccessController? = nil, unlock: @escaping () -> Void = {}) {
            self.coordinator = coordinator
            walletAccess = NativeWalletAccess(access)
            unlockWallet = unlock
        }

        private func acceptsActions(for review: NativeApprovalReview) -> Bool {
            walletAccess.isCurrent && !isRetired && review.isActive
        }

        func activate() {
            guard walletAccess.isCurrent, !isRetired else { return }
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
            guard walletAccess.isCurrent, !isRetired,
                  let snapshot = coordinator.currentPresentation,
                  snapshot.revision != lastRenderedRevision,
                  !isDismissed || snapshot.presentation.isTerminal else { return nil }
            if case .waiting = snapshot.presentation,
               windowController == nil, !allowNewWaitingWindow { return nil }
            lastRenderedRevision = snapshot.revision
            return snapshot
        }

        private func retire() {
            guard !isRetired else { return }
            isRetired = true
            windowCloseObserver.disable()
        }

        func detachForWalletLock() -> NSWindowController? {
            retire()
            let controller = windowController
            if let protected = controller?.contentViewController as? NativeWalletProtectedContent { protected.retireForWalletLock() }
            else { (controller?.contentViewController as? NativeApprovalReviewTeardown)?.invalidateNativeApprovalReview() }
            (controller as? WalletWindowController)?.currentAuthenticationSession?.cancel()
            Window.dismissSheets(in: controller?.window)
            controller?.window?.delegate = nil
            windowController = nil
            return controller
        }
    }

    static let shared = Agent()
#if BW_SAFARI_VM_TESTING
    private static var didRequestSafariVMExtensionState = false
#endif
    private var isReady = false
    private let credentialDependencies: StartupCredentialCoordinator.Dependencies
    private let access: WalletAccessController?
    private let makeApprovalCoordinator: @MainActor (RequestHandle, NativeDeliveryNonce) -> NativeApprovalCoordinator
    private lazy var startupCredentials = StartupCredentialCoordinator(
        dependencies: credentialDependencies
    ) { [weak self] event in
        guard let self else { return }
        switch event {
        case .unlockRequested:
            pendingWalletOpenIntent.record()
        case .authenticated:
            guard access?.checkAccess() != false else { return }
            activateAwaitingApprovals()
            if pendingWalletOpenIntent.consume() { showWallet() }
            else { closeLockedWindows() }
#if BW_SAFARI_VM_TESTING
            recordSafariVMExtensionState()
#endif
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
    private var lockedApprovalWindows = [NSWindowController]()
    private var pendingWalletOpenIntent = PendingWalletOpenIntent()
    private var nativeDeliveryOwner: NativeDeliveryOwner?
    private var approvalInbox = ApprovalInbox<ActiveApproval>()

#if BW_SAFARI_VM_TESTING
    @MainActor
    private final class SafariVMActivationPreparationProbe {
        private let preparation: SafariVMFixtures.ActivationPreparation
        private let fixtures = SafariVMFixtures.shared
        private let deadline = Date().addingTimeInterval(15 * 60)
        private var running = true
        private var queryInFlight = false

        init(_ preparation: SafariVMFixtures.ActivationPreparation) {
            self.preparation = preparation
        }

        private var isActive: Bool {
            running && Date() < deadline && fixtures.matchesActivationPreparation(preparation)
        }

        func run() async {
            defer { running = false }
            guard isActive else { return }
            if preparation.showPreferences {
                SFSafariApplication.showPreferencesForExtension(
                    withIdentifier: Identifiers.safariExtensionBundle, completionHandler: nil
                )
            }
            while !Task.isCancelled && isActive {
                if !queryInFlight { query() }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }

        private func query() {
            queryInFlight = true
            Task { @MainActor [weak self] in
                let enabled: Bool?
                let errorDomain: String?
                let errorCode: Int?
                do {
                    let state = try await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: Identifiers.safariExtensionBundle)
                    enabled = state.isEnabled
                    errorDomain = nil
                    errorCode = nil
                } catch {
                    let error = error as NSError
                    enabled = nil
                    errorDomain = String(error.domain.prefix(128))
                    errorCode = error.code
                }
                guard let self else { return }
                queryInFlight = false
                guard isActive else { return }
                fixtures.event("safariExtensionState", metadata: [
                    "enabled": enabled.map { $0 as Any } ?? NSNull(),
                    "errorDomain": errorDomain.map { $0 as Any } ?? NSNull(),
                    "errorCode": errorCode.map { $0 as Any } ?? NSNull(),
                    "preparationNonce": preparation.nonce
                ],
                    operation: .init(requestID: nil, scenarioID: nil, iteration: nil))
            }
        }
    }

    static func prepareSafariVMExtension(_ preparation: SafariVMFixtures.ActivationPreparation) -> Task<Void, Never> {
        let probe = SafariVMActivationPreparationProbe(preparation)
        return Task { @MainActor in await probe.run() }
    }

    private func recordSafariVMExtensionState() {
        guard CurrentApp.isDockApp, !Self.didRequestSafariVMExtensionState else { return }
        Self.didRequestSafariVMExtensionState = true
        let fixtures = SafariVMFixtures.shared
        let operation = fixtures.capture()
        Task { @MainActor in
            do {
                let state = try await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: Identifiers.safariExtensionBundle)
                fixtures.event("safariExtensionState", metadata: [
                    "enabled": state.isEnabled,
                    "errorDomain": NSNull(),
                    "errorCode": NSNull()
                ], operation: operation)
            } catch {
                let error = error as NSError
                fixtures.event("safariExtensionState", metadata: [
                    "enabled": NSNull(),
                    "errorDomain": String(error.domain.prefix(128)),
                    "errorCode": error.code
                ], operation: operation)
            }
        }
    }
#endif

    private override init() {
        let access = ApplicationServices.shared.access
        self.access = access
        var dependencies = StartupCredentialCoordinator.Dependencies()
        dependencies.access = access
        credentialDependencies = dependencies
        makeApprovalCoordinator = Self.liveApprovalCoordinator
        super.init()
        access.addObserver(self)
    }

    init(
        approvalInbox: ApprovalInbox<ActiveApproval>,
        credentialDependencies: StartupCredentialCoordinator.Dependencies = .init(),
        makeApprovalCoordinator: (@MainActor (RequestHandle, NativeDeliveryNonce) -> NativeApprovalCoordinator)? = nil
    ) {
        self.approvalInbox = approvalInbox
        self.credentialDependencies = credentialDependencies
        access = credentialDependencies.access
        self.makeApprovalCoordinator = makeApprovalCoordinator ?? Self.liveApprovalCoordinator
        super.init()
        access?.addObserver(self)
    }

    isolated deinit { access?.removeObserver(self) }

    private static func liveApprovalCoordinator(handle: RequestHandle, nonce: NativeDeliveryNonce) -> NativeApprovalCoordinator {
        ApplicationServices.shared.authority.makeNativeApprovalCoordinator(handle: handle, nativeDeliveryNonce: nonce)
    }

    private var requiresExplicitUnlock: Bool {
        access?.checkAccess() == false && access?.hasLocked == true
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
        case .approval(_, let handle, let nativeDeliveryNonce),
             .toolbarApproval(_, let handle, let nativeDeliveryNonce):
            if case .toolbarApproval = route, requiresExplicitUnlock { open() }
            let key = ApprovalRouteKey(
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce
            )
            if let existing = approvalInbox.coordinator(for: key) {
                guard !requiresExplicitUnlock else { return }
                if existing.isAwaitingAuthentication {
                    resumePendingWork()
                } else {
                    reactivateApprovalIfNeeded(for: key)
                }
                return
            }
            let coordinator = makeApprovalCoordinator(handle, nativeDeliveryNonce)
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
                    if self.access?.checkAccess() == false || self.approvalInbox.active(for: key)?.isRetired == true {
                        if coordinator.currentPresentation?.presentation.isTerminal == true {
                            self.approvalInbox.remove(key)
                        } else if self.approvalInbox.active(for: key)?.isRetired == true {
                            coordinator.reject()
                        }
                        return
                    }
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
        if access?.hasLocked == true, access?.checkAccess() == false {
            showLockedWallet()
            return
        }
        resumePendingWork()
    }

    private func resumePendingWork() {
        guard isReady else { return }
        startPendingApprovals()
        guard pendingWalletOpenIntent.isPending || approvalInbox.hasAwaitingAuthentication else { return }
        guard access?.hasLocked != true || access?.checkAccess() != false else { return }
        startupCredentials.requestAccess(openWallet: pendingWalletOpenIntent.isPending)
    }

    private func startPendingApprovals() {
        guard isReady,
              let nativeDeliveryOwner else { return }
        for coordinator in approvalInbox.coordinators {
            coordinator.start(
                nativeDeliveryOwner: nativeDeliveryOwner
            )
            if requiresExplicitUnlock { coordinator.reject() }
        }
    }

    private func handleReceiptOwnedApproval(_ key: ApprovalRouteKey) {
        guard let coordinator = approvalInbox.coordinator(for: key),
              coordinator.isAwaitingAuthentication else { return }
        if requiresExplicitUnlock {
            coordinator.reject()
            return
        }
        resumePendingWork()
    }

    private func activateAwaitingApprovals() {
        guard access?.checkAccess() != false else { return }
        guard let authorization = startupCredentials.accessSession else { return }
        for key in approvalInbox.awaitingAuthenticationKeys {
            activateApproval(key, authorization: authorization)
        }
    }

    private func cancelPendingApprovals() {
        for coordinator in approvalInbox.coordinators {
            coordinator.cancelBeforeAuthentication()
        }
    }

    func applicationDidBecomeActive() {
        access?.checkAccess()
        startupCredentials.refresh()
    }

    func walletAccessDidLock() {
        pendingWalletOpenIntent.cancel()
        startupCredentials.lock()
        (walletWindowController as? WalletWindowController)?.walletAccessDidLock()
        let coordinators = approvalInbox.coordinators
        for coordinator in coordinators {
            let key = ApprovalRouteKey(handle: coordinator.handle, nativeDeliveryNonce: coordinator.nativeDeliveryNonce)
            if let controller = approvalInbox.active(for: key)?.detachForWalletLock(),
               let window = controller.window, Window.isVisibleContentWindow(window) {
                configureLockedWindow(controller)
                if walletWindowController?.window.map(Window.isVisibleContentWindow) != true {
                    walletWindowController = controller
                } else {
                    lockedApprovalWindows.append(controller)
                }
            }
            coordinator.reject()
        }
    }

    private func configureLockedWindow(_ controller: NSWindowController) {
        guard let controller = controller as? WalletWindowController else { return }
        controller.bindAccess(access) { [weak self] in self?.unlockWallet() }
        controller.walletAccessDidLock()
    }

    private func showLockedWallet() {
        let controller: NSWindowController
        if let existing = walletWindowController {
            controller = existing
        } else {
            controller = Window.showNew(closeOthers: false, activates: false)
            walletWindowController = controller
        }
        configureLockedWindow(controller)
        Window.reactivateWindow(controller)
    }

    private func unlockWallet() {
        guard access?.checkAccess() == false else { return }
        if !approvalInbox.hasAwaitingAuthentication { pendingWalletOpenIntent.record() }
        startupCredentials.requestAccess()
    }

    private func closeLockedWindows() {
        let controllers = lockedApprovalWindows
        lockedApprovalWindows.removeAll()
        for controller in controllers { controller.close() }
        if walletWindowController?.contentViewController is WalletLockedViewController {
            walletWindowController?.close()
            walletWindowController = nil
        }
    }

    private func showWallet() {
        guard access?.checkAccess() != false else { return }
        if let walletWindowController,
           let window = walletWindowController.window,
           Window.isVisibleContentWindow(window) {
            if walletWindowController.contentViewController is WalletLockedViewController {
                let accounts = AccountsListViewController()
                accounts.walletAccess = NativeWalletAccess(access)
                guard (walletWindowController as? WalletWindowController)?.installProtectedContent(
                    accounts, access: accounts.walletAccess
                ) == true else { return }
            }
            guard access?.checkAccess() != false else { return }
            Window.reactivateWindow(walletWindowController)
            let extras = lockedApprovalWindows
            lockedApprovalWindows.removeAll()
            extras.forEach { $0.close() }
            return
        }
        let accountsList = AccountsListViewController()
        accountsList.walletAccess = NativeWalletAccess(access)
        let windowController = Window.showNew(closeOthers: CurrentApp.isDockApp, activates: false)
        windowController.bindAccess(access) { [weak self] in self?.unlockWallet() }
        walletWindowController = windowController
        guard windowController.installProtectedContent(accountsList, access: accountsList.walletAccess) else { return }
        Window.reactivateWindow(windowController)
    }

    private func activateApproval(_ key: ApprovalRouteKey, authorization: WalletAccessSession) {
        guard let coordinator = approvalInbox.coordinator(for: key),
              coordinator.isAwaitingAuthentication else { return }
        if approvalInbox.active(for: key) == nil {
            let approval = ActiveApproval(coordinator: coordinator, access: access) { [weak self] in self?.unlockWallet() }
            guard approvalInbox.activate(approval, for: key) else { return }
        }
        coordinator.resumeAfterAuthentication(authorization: authorization)
    }

    func renderCurrentPresentation(
        for handle: RequestHandle,
        coordinator: NativeApprovalCoordinator,
        allowNewWaitingWindow: Bool = false
    ) {
        guard let approval = activeApproval(for: handle, coordinator: coordinator) else { return }
        guard access?.checkAccess() != false, !approval.isRetired else {
            if coordinator.currentPresentation?.presentation.isTerminal == true {
                approvalInbox.remove(ApprovalRouteKey(handle: handle, nativeDeliveryNonce: coordinator.nativeDeliveryNonce))
            } else {
                coordinator.reject()
            }
            return
        }
        guard let snapshot = approval.beginRenderingCurrentPresentation(
                  allowNewWaitingWindow: allowNewWaitingWindow
              ) else { return }
        let finishedWindowAction = approval.present(snapshot.presentation)
        guard access?.checkAccess() != false, !approval.isRetired || finishedWindowAction != nil else { return }
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
        guard access?.checkAccess() != false else { return false }
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
        for handle: RequestHandle,
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
        guard access?.checkAccess() != false else { return }
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
        case .approval(let review):
            present(review)
        case .waiting:
            showWaiting()
        case .retryRequired:
            showFailureSurface(retry: true)
        case .rejecting:
            showFailureSurface()
        case .interrupted:
            if isDismissed { return close() }
            showFailureSurface(reason: Strings.approvalInterrupted)
            retire()
            return Agent.FinishedApprovalWindowAction.none
        case .finished, .superseded:
            return close()
        }
        if walletAccess.isCurrent, !isRetired,
           let windowController, let window = windowController.window,
           !Window.isVisibleContentWindow(window) {
            windowController.showWindow(nil)
        }
        return nil
    }

    private func present(_ review: NativeApprovalReview) {
        guard review.isActive,
              let windowController = approvalWindow(peer: review.request.peerMeta) else { return }
        switch review.action {
        case .selectAccount(let action):
            presentAccountSelection(action, mode: .selectAccount, review: review)
        case .switchAccount(let action):
            presentAccountSelection(action, mode: .switchAccount, review: review)
        case .approveMessage(let action):
            showApproveMessage(action, review: review)
        case .approveTransaction(let action):
            let controller = ApproveTransactionViewController.with(
                transaction: action.transaction,
                chain: action.chain,
                account: action.account,
                walletId: action.walletId,
                review: review
            ) { [weak self] approval in
                guard let self, acceptsActions(for: review) else {
                    approval?.authorization.invalidate()
                    return
                }
                if let approval {
                    coordinator.approveTransaction(
                        approval.transaction,
                        reviewedNetwork: action.resolvedNetwork,
                        review: review,
                        authorization: approval.authorization
                    )
                } else {
                    coordinator.reject(review: review)
                }
            }
            controller.walletAccess = walletAccess
            installProtectedContent(controller, in: windowController)
        case .addEthereumChain(let action):
            presentAddEthereumChain(action, review: review)
        }
    }

    private func approvalWindow(peer: PeerMeta? = nil) -> NSWindowController? {
        guard walletAccess.isCurrent, !isRetired else { return nil }
        if let windowController {
            if let peer {
                (windowController as? WalletWindowController)?.approvalPeer = peer
            }
            return windowController
        }
        let controller = Window.showNew(
            closeOthers: false,
            approvalPeer: peer ?? coordinator.peer,
            activates: false
        )
        controller.bindAccess(walletAccess.controller, unlock: unlockWallet)
        windowController = controller
        guard walletAccess.isCurrent, !isRetired else { return nil }
        return controller
    }

    @discardableResult
    private func installProtectedContent(_ content: NSViewController, in controller: NSWindowController) -> Bool {
        if let walletWindow = controller as? WalletWindowController {
            return walletWindow.installProtectedContent(content, access: walletAccess) && !isRetired
        }
        guard walletAccess.isCurrent, !isRetired else { return false }
        _ = content.view
        guard walletAccess.isCurrent, !isRetired else { return false }
        controller.contentViewController = content
        return walletAccess.isCurrent && !isRetired
    }

    private func presentAddEthereumChain(
        _ action: AddEthereumChainAction,
        review: NativeApprovalReview
    ) {
        guard let controller = approvalWindow(),
              installWaitingSurface(reason: Strings.loading, in: controller),
              acceptsActions(for: review) else { return }
        guard let window = controller.window else {
            coordinator.reject(review: review)
            return
        }
        controller.showWindow(nil)
        guard acceptsActions(for: review) else { return }
        let alert = Alert()
        alert.messageText = Strings.addNetwork
        alert.informativeText = action.chainToAdd.chainName + "\n\n" + action.chainToAdd.defaultRpcUrl
        alert.alertStyle = .informational
        alert.addButton(withTitle: Strings.ok).setAccessibilityIdentifier("safari.approval.approve")
        alert.addButton(withTitle: Strings.cancel).setAccessibilityIdentifier("safari.approval.reject")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, acceptsActions(for: review) else { return }
            if response == .alertFirstButtonReturn {
                guard walletAccess.beginAction() else { return }
                coordinator.approveAddEthereumChain(review: review)
            } else {
                coordinator.reject(review: review)
            }
        }
    }

    private func presentAccountSelection(
        _ action: SelectAccountAction,
        mode: NativeAccountSelectionMode,
        review: NativeApprovalReview
    ) {
        let session = NativeAccountSelectionSession(action: action, mode: mode, review: review) {
            [weak self] accounts, network in
            guard let self, acceptsActions(for: review) else { return }
            guard let accounts else {
                coordinator.reject(review: review)
                return
            }
            let ethereumNetwork = accounts.contains {
                $0.account.coin == .ethereum
            } ? network : nil
            coordinator.approveAccounts(accounts, ethereumNetwork: ethereumNetwork, review: review)
        }
        let controller = NativeAccountSelectionViewController(accountSelection: session)
        controller.walletAccess = walletAccess
        guard let window = approvalWindow() else { return }
        installProtectedContent(controller, in: window)
    }

    private func showApproveMessage(
        _ action: SignMessageAction,
        review: NativeApprovalReview
    ) {
        guard let controller = approvalWindow() else { return }
        let window = controller.window
        var authenticationTask: Task<Void, Never>?
        var didResolveAuthentication = false
        let approveViewController = ApproveViewController.with(
            subject: action.subject,
            meta: action.meta,
            account: action.account,
            walletId: action.walletId,
            solanaClusterOptions: action.solanaClusterOptions,
            review: review
        ) { [weak self, weak window] decision in
            guard let self, acceptsActions(for: review) else { return }
            guard case .approved = decision else {
                guard !didResolveAuthentication else { return }
                didResolveAuthentication = true
                coordinator.reject(review: review)
                return
            }
            guard let window else {
                coordinator.reject(review: review)
                return
            }
            guard case .approved(let cluster) = decision,
                  let challenge = review.makeMessageAuthenticationChallenge(solanaCluster: cluster) else {
                coordinator.reject(review: review)
                return
            }
            authenticationTask?.cancel()
            authenticationTask = Task { [weak self, weak window] in
                defer { challenge.invalidate() }
                guard self?.acceptsActions(for: review) == true, !Task.isCancelled else { return }
                let authorization = await Window.authenticate(
                    in: window,
                    reason: action.subject.asAuthenticationReason,
                    challenge: challenge,
                    review: review
                )
                guard let self, !Task.isCancelled, acceptsActions(for: review), !didResolveAuthentication else { return }
                didResolveAuthentication = true
                authenticationTask = nil
                if let authorization {
                    coordinator.approveMessage(solanaCluster: cluster, review: review, authorization: authorization)
                    (window?.contentViewController as? ApproveViewController)?.enableWaiting()
                } else {
                    coordinator.reject(review: review)
                }
            }
        }
        approveViewController.localWindowCloseCompletion = {
            authenticationTask?.cancel()
            authenticationTask = nil
            didResolveAuthentication = true
        }
        approveViewController.walletAccess = walletAccess
        installProtectedContent(approveViewController, in: controller)
    }

    private func showWaiting() {
        guard let controller = approvalWindow() else { return }
        installWaitingSurface(reason: Strings.loading, in: controller)
    }

    private func showFailureSurface(retry: Bool = false, reason: String = Strings.somethingWentWrong) {
        guard let controller = approvalWindow() else { return }
        installWaitingSurface(
            reason: reason,
            in: controller,
            isWorking: false,
            retryAction: retry ? { [weak self] in
                guard let self, !isRetired, walletAccess.beginAction() else { return }
                coordinator.retryRecovery()
            } : nil
        )
    }

    @discardableResult
    private func installWaitingSurface(
        reason: String,
        in windowController: NSWindowController,
        isWorking: Bool = true,
        retryAction: (() -> Void)? = nil
    ) -> Bool {
        guard walletAccess.isCurrent, !isRetired else { return false }
        let outgoing = windowController.contentViewController
        if !(outgoing is WaitingViewController) {
            windowController.window?.delegate = nil
        }
        Self.dismissApprovalSheets(in: windowController.window)
        guard walletAccess.isCurrent, !isRetired else { return false }
        if let waiting = outgoing as? WaitingViewController {
            waiting.update(reason: reason, isWorking: isWorking, retryAction: retryAction)
            return true
        }
        let waiting = WaitingViewController.with(
            reason: reason,
            isWorking: isWorking,
            retryAction: retryAction
        ) {
            Window.activateBrowser(specific: .safari)
        }
        return installProtectedContent(waiting, in: windowController)
    }

    @discardableResult
    private func close() -> Agent.FinishedApprovalWindowAction {
        guard !isRetired else { return .none }
        let window = windowController?.window
        let action = Self.finishedApprovalWindowAction(
            windowNumber: window?.windowNumber,
            isVisible: window?.isVisible == true,
            isMiniaturized: window?.isMiniaturized == true
        )
        retire()
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
        guard walletAccess.isCurrent, !isRetired, coordinator.canReactivate else { return }
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
