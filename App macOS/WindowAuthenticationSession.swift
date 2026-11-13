import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Cocoa

@MainActor
final class WindowAuthenticationSession: NSObject, NativeApprovalReviewTeardown, WalletAccessObserver {
    @MainActor
    struct Dependencies {
        var credentials = ApplicationServices.shared.credentials
        var attemptBiometrics: @MainActor (String, WalletAuthenticationChallenge) async -> WalletAuthenticationResult? = {
            await WindowAuthenticationSession.attemptBiometrics(reason: $0, challenge: $1)
        }
    }

    private enum State {
        case idle, biometrics, password, unavailable, ending(WalletAuthenticationResult), finished
    }

    private weak var owner: NSWindow?
    private let reason: AuthenticationReason
    private let challenge: WalletAuthenticationChallenge
    private let review: NativeApprovalReview?
    private let dependencies: Dependencies
    private let walletAccess: NativeWalletAccess
#if BW_SAFARI_VM_TESTING
    private let fixtureOperation: SafariVMFixtures.Operation
#endif
    private var state = State.idle
    private var task: Task<Void, Never>?
    private var continuation: CheckedContinuation<WalletAuthenticationResult, Never>?
    private var closeObserver: NativeApprovalWindowCloseObserver?
    private(set) var sheet: NSWindow?

    init(
        owner: NSWindow,
        reason: AuthenticationReason,
        challenge: WalletAuthenticationChallenge,
        review: NativeApprovalReview?,
        access: NativeWalletAccess,
        dependencies: Dependencies = Dependencies()
    ) {
        self.owner = owner
        self.reason = reason
        self.challenge = challenge
        self.review = review
        self.dependencies = dependencies
        walletAccess = access
#if BW_SAFARI_VM_TESTING
        fixtureOperation = review.map { SafariVMFixtures.shared.capture(handle: $0.handle) } ?? SafariVMFixtures.shared.capture()
#endif
        super.init()
        access.controller.addObserver(self)
    }

    isolated deinit {
        task?.cancel()
        closeObserver?.disable()
        walletAccess.controller.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    static func attemptBiometrics(reason: String, challenge: WalletAuthenticationChallenge) async -> WalletAuthenticationResult? {
        let credentials = ApplicationServices.shared.credentials
        guard credentials.canUseBiometrics else { return nil }
        return await credentials.attemptBiometrics(reason: reason, challenge: challenge)
    }

    func run() async -> WalletAuthenticationResult {
        guard case .idle = state, !Task.isCancelled, validateOwner() else {
            challenge.invalidate()
            return .cancelled
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled, validateOwner() else {
                    finish(.cancelled)
                    return
                }
                start()
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
        guard !Task.isCancelled, validateOwner() else {
            result.grant?.invalidate()
            return .cancelled
        }
        return result
    }

    func cancel() {
        finish(.cancelled)
    }

    func invalidateNativeApprovalReview() {
        cancel()
    }

    func walletAccessDidLock() { cancel() }

    private func validateOwner() -> Bool {
        guard walletAccess.validateCurrentAccess(), review?.isActive != false, let owner else { return false }
        return Window.isVisibleContentWindow(owner)
    }

    private func start() {
        guard let owner else {
            finish(.cancelled)
            return
        }
        state = .biometrics
        let observer = NativeApprovalWindowCloseObserver { [weak self] in self?.cancel() }
        closeObserver = observer
        observer.observe(owner)
        review?.register(self)
        guard case .biometrics = state else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPassword), name: .walletsChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPassword), name: NSApplication.didBecomeActiveNotification, object: nil
        )
        let attempt = dependencies.attemptBiometrics
        let reason = reason.title
        let challenge = challenge
        task = Task { [weak self] in
#if BW_SAFARI_VM_TESTING
            do { try await SafariVMFixtures.shared.checkpoint("beforeAuthentication", requestID: self?.review?.request.id, operation: self?.fixtureOperation) }
            catch { self?.finish(.cancelled); return }
#endif
            let outcome = await attempt(reason, challenge)
            guard let self, !Task.isCancelled, case .biometrics = state else {
                if case .granted(let grant)? = outcome { grant.invalidate() }
                return
            }
            task = nil
            guard validateOwner() else {
                finish(.cancelled)
                return
            }
            if let outcome { finish(outcome) }
            else { presentPassword() }
        }
    }

    private func presentPassword() {
        guard validateOwner(), let owner else {
            finish(.cancelled)
            return
        }
        state = .password
        let controller = PasswordViewController.with(
            configuration: .init(mode: .enter, reason: reason), beginAction: walletAccess.beginAction
        ) { [weak self] action in self?.handle(action) }
        let sheet = NSWindow(contentViewController: controller)
        sheet.styleMask = [.titled]
        sheet.isReleasedWhenClosed = false
        self.sheet = sheet
        refreshPassword()
        guard self.sheet === sheet else { return }
        owner.beginSheet(sheet) { [weak self, weak sheet] _ in
            guard let self, let sheet, self.sheet === sheet else { return }
            if case .ending = state {} else { state = .ending(.cancelled) }
            passwordController?.retire()
            sheet.orderOut(nil)
            self.sheet = nil
            complete()
        }
    }

    @objc private func refreshPassword() {
        switch state {
        case .password, .unavailable: break
        default: return
        }
        guard validateOwner() else {
            finish(.cancelled)
            return
        }
        let wasUnavailable: Bool
        if case .unavailable = state { wasUnavailable = true }
        else { wasUnavailable = false }
        do {
            guard try dependencies.credentials.passwordState() == .present else {
                showUnavailable()
                return
            }
            state = .password
            passwordController?.render(
                .init(mode: .enter, reason: reason), clearInput: wasUnavailable
            )
        } catch {
            showUnavailable()
        }
    }

    private var passwordController: PasswordViewController? {
        sheet?.contentViewController as? PasswordViewController
    }

    private func showUnavailable() {
        state = .unavailable
        passwordController?.render(.init(mode: .enter, reason: reason, availability: .unavailable))
    }

    private func handle(_ action: PasswordViewController.Action) {
        switch state {
        case .password, .unavailable: break
        default: return
        }
        switch action {
        case .cancel:
            finish(.cancelled)
        case .retry:
            refreshPassword()
        case .submit(let password):
            guard case .password = state else { return }
            refreshPassword()
            guard case .password = state else { return }
            do {
                if let grant = try dependencies.credentials.verify(password: password, challenge: challenge) {
                    finish(.granted(grant))
                }
            } catch WalletCredentialError.authorizationUnavailable {
                finish(.failed)
            } catch {
                showUnavailable()
            }
        }
    }

    private func finish(_ result: WalletAuthenticationResult) {
        if let grant = result.grant, !walletAccess.validateCurrentAccess() {
            grant.invalidate()
            finish(.cancelled)
            return
        }
        switch state {
        case .finished:
            result.grant?.invalidate()
            return
        case .ending(let previous):
            if result.grant == nil {
                previous.grant?.invalidate()
                challenge.invalidate()
                state = .ending(result)
            }
            return
        default: break
        }
        state = .ending(result)
        if result.grant == nil { challenge.invalidate() }
        task?.cancel()
        task = nil
        passwordController?.retire()
        NotificationCenter.default.removeObserver(self)
        guard let sheet else {
            complete()
            return
        }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet, returnCode: .abort)
        } else {
            sheet.orderOut(nil)
            self.sheet = nil
            complete()
        }
    }

    private func complete() {
        guard case .ending(let result) = state else { return }
        state = .finished
#if BW_SAFARI_VM_TESTING
        SafariVMFixtures.shared.event("authenticationCompleted", requestID: review?.request.id,
            metadata: ["succeeded": result.grant != nil, "authentication": SafariVMFixtures.shared.isLocal ? "password-sheet" : "system"], operation: fixtureOperation)
#endif
        closeObserver?.disable()
        closeObserver = nil
        NotificationCenter.default.removeObserver(self)
        let accepted = walletAccess.validateCurrentAccess() ? result : .cancelled
        if accepted.grant == nil { result.grant?.invalidate() }
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: accepted)
    }
}
