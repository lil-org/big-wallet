// ∅ 2026 lil org

import Cocoa

@MainActor
final class WindowAuthenticationSession: NSObject, NativeApprovalReviewTeardown {
    struct Dependencies {
        var keychain = Keychain.shared
        var attemptBiometrics: @MainActor (String) async -> DeviceAuthentication.Outcome? = {
            await WindowAuthenticationSession.attemptBiometrics(reason: $0)
        }
    }

    private enum State {
        case idle, biometrics, password, unavailable, ending(Bool), finished
    }

    private weak var owner: NSWindow?
    private let reason: AuthenticationReason
    private let reviewLifetime: NativeApprovalReviewLifetime?
    private let dependencies: Dependencies
    private var state = State.idle
    private var task: Task<Void, Never>?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var closeObserver: NativeApprovalWindowCloseObserver?
    private(set) var sheet: NSWindow?

    init(
        owner: NSWindow,
        reason: AuthenticationReason,
        reviewLifetime: NativeApprovalReviewLifetime?,
        dependencies: Dependencies = Dependencies()
    ) {
        self.owner = owner
        self.reason = reason
        self.reviewLifetime = reviewLifetime
        self.dependencies = dependencies
        super.init()
    }

    isolated deinit {
        task?.cancel()
        closeObserver?.disable()
        NotificationCenter.default.removeObserver(self)
    }

    static func attemptBiometrics(reason: String) async -> DeviceAuthentication.Outcome? {
        guard DeviceAuthentication.canUseBiometrics else { return nil }
        return await DeviceAuthentication.attemptBiometrics(reason: reason)
    }

    func run() async -> Bool {
        guard case .idle = state, !Task.isCancelled, ownerIsAvailable else { return false }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled, ownerIsAvailable else {
                    finish(false)
                    return
                }
                start()
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
        return result && !Task.isCancelled && ownerIsAvailable
    }

    func cancel() {
        finish(false)
    }

    func invalidateNativeApprovalReview() {
        cancel()
    }

    private var ownerIsAvailable: Bool {
        guard reviewLifetime?.isActive != false, let owner else { return false }
        return Window.isVisibleContentWindow(owner)
    }

    private func start() {
        guard let owner else {
            finish(false)
            return
        }
        state = .biometrics
        let observer = NativeApprovalWindowCloseObserver { [weak self] in self?.cancel() }
        closeObserver = observer
        observer.observe(owner)
        reviewLifetime?.register(self)
        guard case .biometrics = state else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPassword), name: .walletsChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPassword), name: NSApplication.didBecomeActiveNotification, object: nil
        )
        let attempt = dependencies.attemptBiometrics
        let reason = reason.title
        task = Task { [weak self] in
            let outcome = await attempt(reason)
            guard let self, !Task.isCancelled, case .biometrics = state else { return }
            task = nil
            guard ownerIsAvailable else {
                finish(false)
                return
            }
            if let outcome { finish(outcome == .succeeded) }
            else { presentPassword() }
        }
    }

    private func presentPassword() {
        guard ownerIsAvailable, let owner else {
            finish(false)
            return
        }
        state = .password
        let controller = PasswordViewController.with(
            configuration: .init(mode: .enter, reason: reason)
        ) { [weak self] action in self?.handle(action) }
        let sheet = NSWindow(contentViewController: controller)
        sheet.styleMask = [.titled]
        sheet.isReleasedWhenClosed = false
        self.sheet = sheet
        refreshPassword()
        guard self.sheet === sheet else { return }
        owner.beginSheet(sheet) { [weak self, weak sheet] _ in
            guard let self, let sheet, self.sheet === sheet else { return }
            if case .ending = state {} else { state = .ending(false) }
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
        guard ownerIsAvailable else {
            finish(false)
            return
        }
        let wasUnavailable: Bool
        if case .unavailable = state { wasUnavailable = true }
        else { wasUnavailable = false }
        do {
            guard try dependencies.keychain.passwordState() == .present else {
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
            finish(false)
        case .retry:
            refreshPassword()
        case .submit(let password):
            guard case .password = state else { return }
            refreshPassword()
            guard case .password = state else { return }
            do {
                if try DeviceAuthentication.verify(password: password, keychain: dependencies.keychain) {
                    finish(true)
                }
            } catch {
                showUnavailable()
            }
        }
    }

    private func finish(_ result: Bool) {
        switch state {
        case .finished: return
        case .ending:
            if !result { state = .ending(false) }
            return
        default: break
        }
        state = .ending(result)
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
        closeObserver?.disable()
        closeObserver = nil
        NotificationCenter.default.removeObserver(self)
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}
