// ∅ 2026 lil org

import UIKit

@MainActor
struct LocalAuthentication {
    enum Prompt: Equatable {
        case password(reason: String?), unavailable, mismatch
    }

    static func attempt(reason: String, presentPasswordAlertFrom presenter: @escaping @MainActor @Sendable () -> UIViewController?, passwordReason: String?) async -> Bool {
        await attempt(
            passwordReason: passwordReason,
            biometrics: { await DeviceAuthentication.attemptBiometrics(reason: reason) },
            passwordState: { try Keychain.shared.passwordState() },
            verifyPassword: { try DeviceAuthentication.verify(password: $0) }
        ) { prompt in
            switch prompt {
            case .password(let reason):
                await AlertRequest().present(from: presenter, title: Strings.enterPassword, message: reason, requestsPassword: true)
            case .unavailable:
                await AlertRequest().present(from: presenter, title: Strings.failedToLoad, message: nil, requestsPassword: false, retry: true)
            case .mismatch:
                await AlertRequest().present(from: presenter, title: Strings.passwordDoesNotMatch, message: nil, requestsPassword: false)
            }
        }
    }

    static func attempt(
        passwordReason: String?,
        biometrics: () async -> DeviceAuthentication.Outcome,
        passwordState: () throws -> Keychain.PasswordState,
        verifyPassword: (String) throws -> Bool,
        prompt: (Prompt) async -> String?
    ) async -> Bool {
        let outcome = await biometrics()
        guard !Task.isCancelled else { return false }
        if outcome == .succeeded {
            while !Task.isCancelled {
                do {
                    guard try passwordState() == .present else {
                        throw Keychain.KeychainError.failedToRead(errSecItemNotFound)
                    }
                    return true
                } catch {
                    guard await prompt(.unavailable) != nil else { return false }
                }
            }
            return false
        }
        guard let password = await prompt(.password(reason: passwordReason)),
              !Task.isCancelled else { return false }
        while !Task.isCancelled {
            do {
                if try verifyPassword(password) { return true }
                break
            } catch {
                guard await prompt(.unavailable) != nil else { return false }
            }
        }
        guard !Task.isCancelled else { return false }
        _ = await prompt(.mismatch)
        return false
    }

    @MainActor
    final class AlertRequest {
        typealias Show = @MainActor (UIViewController, UIAlertController) -> Void
        typealias Dismiss = @MainActor (UIAlertController, Bool, @escaping @MainActor @Sendable () -> Void) -> Void

        private var continuation: CheckedContinuation<String?, Never>?
        private var alert: UIAlertController?
        private var isFinishing = false
        private var isCancelled = false
        private let show: Show
        private let dismiss: Dismiss

        init(
            show: @escaping Show = { $0.present($1, animated: true) },
            dismiss: @escaping Dismiss = { $0.dismissAfterCurrentTransition(animated: $1, completion: $2) }
        ) {
            self.show = show
            self.dismiss = dismiss
        }

        func present(from presenter: @escaping @MainActor @Sendable () -> UIViewController?, title: String, message: String?, requestsPassword: Bool, retry: Bool = false) async -> String? {
            guard !Task.isCancelled else { return nil }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled, let controller = presenter() else {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.continuation = continuation
                    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
                    self.alert = alert
                    if requestsPassword {
                        alert.addTextField {
                            $0.isSecureTextEntry = true
                            $0.placeholder = Strings.password
                        }
                    }
                    alert.addAction(UIAlertAction(title: retry ? Strings.tryAgain : Strings.ok, style: .default) { [weak self, weak alert] _ in
                        self?.finish(requestsPassword ? alert?.textFields?.first?.text : "")
                    })
                    if requestsPassword || retry {
                        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel) { [weak self] _ in
                            self?.finish(nil)
                        })
                    }
                    show(controller, alert)
                }
            } onCancel: {
                Task { @MainActor in self.cancel() }
            }
        }

        func finish(_ value: String?) {
            guard !isFinishing, continuation != nil else { return }
            isFinishing = true
            alert?.textFields?.forEach { $0.text = nil }
            guard let alert else {
                resolve(value)
                return
            }
            dismiss(alert, !isCancelled) { [self] in resolve(value) }
        }

        private func resolve(_ value: String?) {
            let continuation = continuation
            self.continuation = nil
            alert = nil
            continuation?.resume(returning: isCancelled ? nil : value)
        }

        func cancel() {
            isCancelled = true
            finish(nil)
        }

    }
}
