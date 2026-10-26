import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import UIKit

@MainActor
struct LocalAuthentication {
    enum Prompt: Equatable {
        case password(reason: String?), unavailable, mismatch
    }

    static func attempt(reason: String, presentPasswordAlertFrom presenter: @escaping @MainActor @Sendable () -> UIViewController?, passwordReason: String?) async -> Bool {
        let credentials = ApplicationServices.shared.credentials
        let challenge = credentials.makeWalletAccessChallenge()
        guard let grant = await authorize(reason: reason, presentPasswordAlertFrom: presenter, passwordReason: passwordReason, challenge: challenge, credentials: credentials) else { return false }
        return credentials.accessSession(authorization: grant) != nil
    }

    static func authorize(
        reason: String,
        presentPasswordAlertFrom presenter: @escaping @MainActor @Sendable () -> UIViewController?,
        passwordReason: String?,
        challenge: WalletAuthenticationChallenge,
        credentials: WalletCredentials
    ) async -> WalletAuthenticationGrant? {
        let grant = await withTaskCancellationHandler {
            await authorize(
                passwordReason: passwordReason,
                biometrics: {
                    guard try credentials.passwordState() == .present else {
                        throw WalletCredentialError.failedToRead(errSecItemNotFound)
                    }
                    let result = await credentials.attemptBiometrics(reason: reason, challenge: challenge)
                    if case .granted(let grant) = result { return grant }
                    guard try credentials.passwordState() == .present else {
                        throw WalletCredentialError.failedToRead(errSecItemNotFound)
                    }
                    return nil
                },
                verifyPassword: { try credentials.verify(password: $0, challenge: challenge) }
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
        } onCancel: {
            challenge.invalidate()
        }
        guard !Task.isCancelled, let grant else {
            challenge.invalidate()
            return nil
        }
        return grant
    }

    static func authorize<Value: Sendable>(
        passwordReason: String?,
        biometrics: () async throws -> Value?,
        verifyPassword: (String) throws -> Value?,
        prompt: (Prompt) async -> String?
    ) async -> Value? {
        while !Task.isCancelled {
            do {
                if let value = try await biometrics() { return Task.isCancelled ? nil : value }
                break
            } catch WalletCredentialError.authorizationUnavailable {
                return nil
            } catch {
                guard await prompt(.unavailable) != nil else { return nil }
            }
        }
        guard !Task.isCancelled,
              let password = await prompt(.password(reason: passwordReason)),
              !Task.isCancelled else { return nil }
        while !Task.isCancelled {
            do {
                if let value = try verifyPassword(password) { return Task.isCancelled ? nil : value }
                break
            } catch WalletCredentialError.authorizationUnavailable {
                return nil
            } catch {
                guard await prompt(.unavailable) != nil else { return nil }
            }
        }
        guard !Task.isCancelled else { return nil }
        _ = await prompt(.mismatch)
        return nil
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
