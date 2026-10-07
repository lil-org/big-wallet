// ∅ 2026 lil org

import Cocoa

@MainActor
final class StartupCredentialCoordinator: NSObject {
    enum Event: Equatable {
        case authenticated, cancelled, setupRequiredInDockApp, handedOff
    }

    struct Dependencies {
        var keychain = Keychain.shared
        var canCreatePassword = CurrentApp.canCreatePassword
        var attemptBiometrics: @MainActor (String) async -> DeviceAuthentication.Outcome? = {
            await WindowAuthenticationSession.attemptBiometrics(reason: $0)
        }
        var openDock: @MainActor () async -> Bool = DockAppLauncher.openDockApp
    }

    private enum State {
        case idle, welcome, creating, repeating(String), authenticating
        case enteringPassword, saving, unavailable, handingOff, authenticated
    }

    private let dependencies: Dependencies
    private let onEvent: (Event) -> Void
    private var state = State.idle
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var closeObserver: NativeApprovalWindowCloseObserver?
    private(set) var windowController: WalletWindowController?

    init(dependencies: Dependencies = Dependencies(), onEvent: @escaping (Event) -> Void) {
        self.dependencies = dependencies
        self.onEvent = onEvent
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil
        )
    }

    isolated deinit {
        task?.cancel()
        closeObserver?.disable()
        retirePresentation()
        NotificationCenter.default.removeObserver(self)
    }

    func requestAccess() {
        switch state {
        case .unavailable, .saving: break
        default: reconcile()
        }
        if let windowController { Window.reactivateWindow(windowController) }
    }

    func refresh() {
        switch state {
        case .idle, .authenticated, .unavailable, .saving: return
        default: reconcile()
        }
    }

    func cancel() {
        switch state {
        case .idle, .authenticated: return
        default: break
        }
        transition(to: .idle)
        closeWindow()
        onEvent(.cancelled)
    }

    @objc private func walletsChanged() {
        refresh()
    }

    private func reconcile() {
        do {
            switch try dependencies.keychain.passwordState() {
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
                    onEvent(.authenticated)
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
        generation &+= 1
        self.state = state
        let previousTask = task
        task = nil
        previousTask?.cancel()
        retirePresentation()
        return generation
    }

    private func accepts(_ generation: UInt64) -> Bool {
        self.generation == generation
    }

    private func retirePresentation() {
        switch windowController?.contentViewController {
        case let password as PasswordViewController: password.retire()
        case let welcome as WelcomeViewController: welcome.retire()
        case let waiting as WaitingViewController: waiting.retire()
        default: break
        }
    }

    private func present(_ controller: NSViewController, generation: UInt64) {
        guard accepts(generation) else { return }
        if windowController == nil {
            let created = Window.showNew(closeOthers: false)
            guard accepts(generation) else {
                created.close()
                return
            }
            windowController = created
            if let window = created.window {
                let observer = NativeApprovalWindowCloseObserver { [weak self] in self?.cancel() }
                closeObserver = observer
                observer.observe(window)
            }
        }
        guard let windowController, accepts(generation) else { return }
        windowController.window?.delegate = nil
        windowController.contentViewController = controller
        guard accepts(generation) else { return }
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
                do {
                    if try DeviceAuthentication.verify(password: password, keychain: dependencies.keychain) {
                        completeAuthentication()
                    }
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
        if windowController != nil {
            present(WaitingViewController.with(reason: Strings.loading), generation: generation)
        }
        let attempt = dependencies.attemptBiometrics
        task = Task { [weak self] in
            let outcome = await attempt(AuthenticationReason.start.title)
            guard let self, !Task.isCancelled, accepts(generation) else { return }
            task = nil
            do {
                guard try dependencies.keychain.passwordState() == .present else {
                    reconcile()
                    return
                }
                if outcome == .succeeded { completeAuthentication() }
                else { showPassword(mode: .enter) }
            } catch {
                showUnavailable()
            }
        }
    }

    private func completeAuthentication() {
        do {
            guard try dependencies.keychain.passwordState() == .present else {
                reconcile()
                return
            }
        } catch {
            showUnavailable()
            return
        }
        transition(to: .authenticated)
        closeWindow()
        onEvent(.authenticated)
    }

    private func savePassword(_ password: String) {
        guard dependencies.canCreatePassword else { return }
        let controller = windowController?.contentViewController as? PasswordViewController
        let generation = transition(to: .saving)
        controller?.render(.init(mode: .repeatAfterCreate, availability: .saving))
        let keychain = dependencies.keychain
        task = Task { [weak self] in
            let result: Result<Keychain.PasswordCreationResult, Error>
            do { result = .success(try await keychain.createPasswordIfMissing(password)) }
            catch { result = .failure(error) }
            defer {
                if case .success(.created) = result { WalletStoreSync.postLocalAndExternalChange() }
            }
            guard let self, !Task.isCancelled, accepts(generation) else { return }
            task = nil
            switch result {
            case .success(.created): completeAuthentication()
            case .success(.alreadyExists): reconcile()
            case .failure: showUnavailable()
            }
        }
    }

    private func showUnavailable(reason: String = Strings.failedToLoad) {
        if case .unavailable = state { return }
        let generation = transition(to: .unavailable)
        let controller = WaitingViewController.with(
            reason: reason, isWorking: false,
            retryAction: { [weak self] in
                guard let self, accepts(generation) else { return }
                transition(to: .idle)
                reconcile()
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
        task = Task { [weak self] in
            let succeeded = await openDock()
            guard let self, !Task.isCancelled, accepts(generation) else { return }
            task = nil
            guard succeeded else {
                showUnavailable(reason: Strings.somethingWentWrong)
                return
            }
            transition(to: .idle)
            closeWindow()
            onEvent(.handedOff)
        }
    }
}
