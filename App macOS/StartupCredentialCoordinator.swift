import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Cocoa

@MainActor
final class StartupCredentialCoordinator: NSObject, WalletAccessObserver {
    enum Event: Equatable {
        case authenticated, cancelled, setupRequiredInDockApp, handedOff, unlockRequested
    }

    @MainActor
    struct Dependencies {
        var credentials = ApplicationServices.shared.credentials
        var canCreatePassword = CurrentApp.canCreatePassword
        var attemptBiometrics: @MainActor (String, WalletAuthenticationChallenge) async -> WalletAuthenticationResult? = {
            await WindowAuthenticationSession.attemptBiometrics(reason: $0, challenge: $1)
        }
        var openDock: @MainActor () async -> Bool = DockAppLauncher.openDockApp
        var access: WalletAccessController?
    }

    private enum State {
        case idle, welcome, creating, repeating(String), authenticating
        case enteringPassword, saving, unavailable, handingOff, authenticated, locked
    }

    private let dependencies: Dependencies
    private let access: WalletAccessController
    private let onEvent: (Event) -> Void
    private var state = State.idle
    private var presentationGeneration: UInt64 = 0
    private var handoffTask: Task<Void, Never>?
    private var authenticationAttempt: WalletAccessController.AuthenticationAttempt?
    var accessSession: WalletAccessSession? { access.session }
    private var closeObserver: NativeApprovalWindowCloseObserver?
    private(set) var windowController: WalletWindowController?

    init(dependencies: Dependencies = Dependencies(), onEvent: @escaping (Event) -> Void) {
        self.dependencies = dependencies
        access = dependencies.access ?? WalletAccessController(credentials: dependencies.credentials)
        self.onEvent = onEvent
        super.init()
        access.addObserver(self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil
        )
    }

    isolated deinit {
        handoffTask?.cancel()
        access.removeObserver(self)
        authenticationAttempt?.cancel()
        closeObserver?.disable()
        retirePresentation()
        NotificationCenter.default.removeObserver(self)
    }

    func requestAccess(openWallet: Bool = false) {
        if access.validateCurrentAccess() {
            do {
                _ = try access.requireCurrentAccess()
                transition(to: .authenticated)
                closeWindow()
                onEvent(.authenticated)
                return
            } catch {
                if !access.isLocked {
                    showUnavailable(openWallet: openWallet)
                    if let windowController { Window.reactivateWindow(windowController) }
                    return
                }
                if openWallet { onEvent(.unlockRequested) }
            }
        }
        if authenticationAttempt?.isCurrent != true { beginAccessAuthentication() }
        guard authenticationAttempt?.isCurrent == true else { return }
        if case .locked = state { transition(to: .idle) }
        switch state {
        case .unavailable, .saving: break
        default: reconcile()
        }
        if let windowController { Window.reactivateWindow(windowController) }
    }

    func refresh() {
        switch state {
        case .idle, .authenticated, .unavailable, .saving, .locked: return
        default: reconcile()
        }
    }

    func cancel() {
        switch state {
        case .idle, .authenticated, .locked: return
        default: break
        }
        transition(to: .idle)
        cancelAccessAuthentication()
        closeWindow()
        onEvent(.cancelled)
    }

    func lock() {
        if !access.isLocked || !access.hasLocked {
            access.lock(reason: .idle)
        } else {
            walletAccessDidLock()
        }
    }

    func walletAccessDidLock() {
        let previous = authenticationAttempt
        authenticationAttempt = nil
        previous?.cancel()
        transition(to: .locked)
        windowController?.bindAccess(access) { [weak self] in self?.unlock() }
        windowController?.walletAccessDidLock()
    }

    private func unlock() {
        guard access.isLocked else { return }
        onEvent(.unlockRequested)
        requestAccess()
    }

    private func beginAccessAuthentication() {
        let attempt = access.beginAuthentication { [weak self] cancelled in
            guard let self, authenticationAttempt === cancelled else { return }
            authenticationAttempt = nil
            transition(to: .locked)
        }
        if attempt.isCurrent { authenticationAttempt = attempt }
    }

    private func cancelAccessAuthentication() {
        let pending = authenticationAttempt
        authenticationAttempt = nil
        pending?.cancel()
    }

    @objc private func walletsChanged() {
        refresh()
    }

    private func reconcile() {
        do {
            switch try dependencies.credentials.passwordState() {
            case .missing:
                if dependencies.canCreatePassword {
                    switch state {
                    case .welcome, .creating, .repeating: break
                    default: showWelcome()
                    }
                } else {
                    beginDockHandoff()
                }
            case .present:
                switch state {
                case .authenticated:
                    if access.validateCurrentAccess() {
                        onEvent(.authenticated)
                    } else {
                        beginAuthentication()
                    }
                case .authenticating, .enteringPassword:
                    break
                default:
                    beginAuthentication()
                }
            }
        } catch {
            showUnavailable()
        }
    }

    @discardableResult
    private func transition(to state: State) -> UInt64 {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        self.state = state
        let previousTask = handoffTask
        handoffTask = nil
        authenticationAttempt?.cancelOperation()
        previousTask?.cancel()
        guard presentationGeneration == generation else { return generation }
        retirePresentation()
        return generation
    }

    private func accepts(_ generation: UInt64) -> Bool {
        presentationGeneration == generation && authenticationAttempt.map(\.isCurrent) != false
    }

    private func retirePresentation() {
        (windowController?.contentViewController as? any NativeWindowContentRetirement)?.retire()
    }

    private func present(_ controller: NSViewController, generation: UInt64) {
        guard accepts(generation) else { return }
        if windowController == nil {
            let created = Window.showNew(closeOthers: false, activates: false)
            guard accepts(generation) else {
                created.close()
                return
            }
            windowController = created
            created.bindAccess(access) { [weak self] in self?.unlock() }
            if let window = created.window {
                let observer = NativeApprovalWindowCloseObserver { [weak self] in self?.cancel() }
                closeObserver = observer
                observer.observe(window)
            }
        }
        guard let windowController, accepts(generation) else { return }
        windowController.window?.delegate = nil
        guard windowController.installContent(controller, while: { accepts(generation) }) else { return }
        Window.reactivateWindow(windowController)
    }

    private func closeWindow() {
        closeObserver?.disable()
        closeObserver = nil
        let controller = windowController
        windowController = nil
        controller?.window?.delegate = nil
        controller?.close()
    }

    private func showWelcome() {
        let generation = transition(to: .welcome)
        let controller = WelcomeViewController.new { [weak self] in
            guard let self, accepts(generation) else { return }
            reconcile()
            guard accepts(generation) else { return }
            showPassword(mode: .create)
        }
        present(controller, generation: generation)
    }

    private func showPassword(mode: PasswordViewController.Mode, draft: String? = nil) {
        let state: State = switch mode {
        case .create: .creating
        case .repeatAfterCreate: .repeating(draft ?? "")
        case .enter: .enteringPassword
        }
        let generation = transition(to: state)
        let controller = PasswordViewController.with(
            configuration: .init(mode: mode, reason: .start)
        ) { [weak self] action in
            guard let self, accepts(generation) else { return }
            handle(action, generation: generation)
        }
        present(controller, generation: generation)
    }

    private func handle(_ action: PasswordViewController.Action, generation: UInt64) {
        switch action {
        case .retry:
            break
        case .cancel:
            switch state {
            case .creating: showWelcome()
            case .repeating: showPassword(mode: .create)
            case .enteringPassword: cancel()
            default: break
            }
        case .submit(let password):
            reconcile()
            guard accepts(generation) else { return }
            switch state {
            case .creating:
                guard password.isOkAsPassword else { return }
                showPassword(mode: .repeatAfterCreate, draft: password)
            case .repeating(let draft):
                guard password == draft, password.isOkAsPassword else { return }
                savePassword(password)
            case .enteringPassword:
                guard let attempt = authenticationAttempt, attempt.isCurrent else { return }
                let challenge = dependencies.credentials.makeWalletAccessChallenge()
                defer { challenge.invalidate() }
                let operation = attempt.replaceOperation(challenge: challenge)
                do {
                    if let grant = try dependencies.credentials.verify(password: password, challenge: challenge) {
                        completeAuthentication(grant, operation: operation)
                    }
                } catch WalletCredentialError.authorizationUnavailable {
                    cancel()
                } catch {
                    showUnavailable()
                }
            default:
                break
            }
        }
    }

    private func beginAuthentication() {
        let generation = transition(to: .authenticating)
        guard let authenticationAttempt, authenticationAttempt.isCurrent else { return }
        let challenge = dependencies.credentials.makeWalletAccessChallenge()
        if windowController != nil {
            present(WaitingViewController.with(reason: Strings.loading), generation: generation)
        }
        guard accepts(generation) else { challenge.invalidate(); return }
        let attempt = dependencies.attemptBiometrics
        authenticationAttempt.replaceOperation(challenge: challenge) { [weak self] operation in
            let outcome = await attempt(AuthenticationReason.start.title, challenge)
            guard let self, !Task.isCancelled, operation.isCurrent, accepts(generation) else {
                if case .granted(let grant)? = outcome { grant.invalidate() }
                return
            }
            defer { if case .granted(let grant)? = outcome { grant.invalidate() } }
            do {
                guard try dependencies.credentials.passwordState() == .present else {
                    reconcile()
                    return
                }
                if case .granted(let grant)? = outcome { completeAuthentication(grant, operation: operation) }
                else { showPassword(mode: .enter) }
            } catch {
                showUnavailable()
            }
        }
    }

    private func completeAuthentication(_ grant: WalletAuthenticationGrant, operation: WalletAccessController.AuthenticationAttempt.Operation) {
        defer { grant.invalidate() }
        guard operation.isCurrent else { return }
        let generation = presentationGeneration
        do {
            guard try dependencies.credentials.passwordState() == .present else {
                if operation.isCurrent { reconcile() }
                return
            }
        } catch {
            if operation.isCurrent { showUnavailable() }
            return
        }
        guard operation.isCurrent, let attempt = authenticationAttempt,
              let session = dependencies.credentials.accessSession(authorization: grant) else {
            if operation.isCurrent { cancel() }
            return
        }
        guard dependencies.credentials.validateAccess(session) else {
            session.invalidate()
            if operation.isCurrent { cancel() }
            return
        }
        guard operation.complete(session) else {
            if authenticationAttempt === attempt {
                cancelAccessAuthentication()
                walletAccessDidLock()
            }
            return
        }
        guard presentationGeneration == generation, authenticationAttempt === attempt else {
            if authenticationAttempt === attempt { authenticationAttempt = nil }
            return
        }
        authenticationAttempt = nil
        transition(to: .authenticated)
        closeWindow()
        onEvent(.authenticated)
    }

    private func savePassword(_ password: String) {
        guard dependencies.canCreatePassword else { return }
        let controller = windowController?.contentViewController as? PasswordViewController
        let generation = transition(to: .saving)
        controller?.render(.init(mode: .repeatAfterCreate, availability: .saving))
        guard accepts(generation), let authenticationAttempt, authenticationAttempt.isCurrent else { return }
        let credentials = dependencies.credentials
        authenticationAttempt.replaceOperation { [weak self, credentials] operation in
            let result: Result<WalletPasswordCreationResult, Error>
            do { result = .success(try await credentials.createPasswordIfMissing(password)) }
            catch { result = .failure(error) }
            guard let self, !Task.isCancelled, operation.isCurrent, accepts(generation) else { return }
            switch result {
            case .success(.created):
                do {
                    let challenge = credentials.makeWalletAccessChallenge()
                    guard operation.attachChallenge(challenge) else { return }
                    guard let grant = try credentials.verify(password: password, challenge: challenge) else {
                        reconcile()
                        return
                    }
                    completeAuthentication(grant, operation: operation)
                } catch {
                    showUnavailable()
                }
            case .success(.alreadyExists): reconcile()
            case .failure: showUnavailable()
            }
        }
    }

    private func showUnavailable(reason: String = Strings.failedToLoad, openWallet: Bool = false) {
        let generation = transition(to: .unavailable)
        let controller = WaitingViewController.with(
            reason: reason, isWorking: false,
            retryAction: { [weak self] in
                guard let self, accepts(generation) else { return }
                transition(to: .idle)
                requestAccess(openWallet: openWallet)
            }
        )
        present(controller, generation: generation)
    }

    private func beginDockHandoff() {
        if case .handingOff = state {
            onEvent(.setupRequiredInDockApp)
            return
        }
        let generation = transition(to: .handingOff)
        onEvent(.setupRequiredInDockApp)
        guard accepts(generation) else { return }
        if windowController != nil {
            present(WaitingViewController.with(reason: Strings.loading), generation: generation)
        }
        let openDock = dependencies.openDock
        handoffTask = Task { [weak self] in
            let succeeded = await openDock()
            guard let self, !Task.isCancelled, accepts(generation) else { return }
            handoffTask = nil
            guard succeeded else {
                showUnavailable(reason: Strings.somethingWentWrong)
                return
            }
            transition(to: .idle)
            cancelAccessAuthentication()
            closeWindow()
            onEvent(.handedOff)
        }
    }
}
