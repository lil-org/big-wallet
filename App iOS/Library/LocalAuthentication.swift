import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import UIKit

@MainActor
private final class SecretTextFieldUndoHistory: NSObject {
    private struct ObservedManager {
        weak var value: UndoManager?
    }

    private var managers = [ObservedManager]()

    @objc func capture(_ field: UITextField) {
        managers.removeAll { $0.value == nil }
        guard let manager = field.undoManager, !managers.contains(where: { $0.value === manager }) else { return }
        managers.append(ObservedManager(value: manager))
    }

    func clear(_ field: UITextField) {
        capture(field)
        let retainedManagers = managers.compactMap(\.value)
        retainedManagers.forEach { $0.removeAllActions() }
        field.text = nil
        field.resignFirstResponder()
        capture(field)
        retainedManagers.forEach { $0.removeAllActions() }
        managers.compactMap(\.value).forEach { $0.removeAllActions() }
        managers.removeAll()
    }
}

@MainActor
private enum SecretTextFieldAssociatedObjects {
    static var history: UInt8 = 0
}

extension UITextField {
    func prepareSecretDraftHistory() {
        guard objc_getAssociatedObject(self, &SecretTextFieldAssociatedObjects.history) == nil else { return }
        let history = SecretTextFieldUndoHistory()
        objc_setAssociatedObject(self, &SecretTextFieldAssociatedObjects.history, history, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        addTarget(history, action: #selector(SecretTextFieldUndoHistory.capture(_:)), for: [.editingDidBegin, .editingChanged, .editingDidEnd])
        if isFirstResponder { history.capture(self) }
    }

    func clearSecretDraft() {
        prepareSecretDraftHistory()
        let history = objc_getAssociatedObject(self, &SecretTextFieldAssociatedObjects.history) as? SecretTextFieldUndoHistory
        history?.clear(self)
    }
}

@MainActor
struct LocalAuthentication {
    enum Prompt: Equatable {
        case password(reason: String?), unavailable, mismatch
    }

    static func attempt(reason: String, presentPasswordAlertFrom presenter: @escaping @MainActor @Sendable () -> UIViewController?, passwordReason: String?) async -> Bool {
        guard let session = await accessSession(reason: reason, presentPasswordAlertFrom: presenter,
                                               passwordReason: passwordReason) else { return false }
        session.invalidate()
        return true
    }

    static func accessSession(
        reason: String,
        presentPasswordAlertFrom presenter: @escaping @MainActor @Sendable () -> UIViewController?,
        passwordReason: String?,
        credentials: WalletCredentials = ApplicationServices.shared.credentials
    ) async -> WalletAccessSession? {
        let challenge = credentials.makeWalletAccessChallenge()
        guard let grant = await authorize(reason: reason, presentPasswordAlertFrom: presenter, passwordReason: passwordReason, challenge: challenge, credentials: credentials) else { return nil }
        return credentials.accessSession(authorization: grant)
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
        private var pendingResult: String?
        private var confirmation: (() -> String?)?
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

        func present(
            from presenter: @escaping @MainActor @Sendable () -> UIViewController?,
            title: String,
            message: String?,
            requestsPassword: Bool,
            retry: Bool = false,
            authorizeConfirmation: @escaping @MainActor () -> Bool = { true }
        ) async -> String? {
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
                            $0.prepareSecretDraftHistory()
                            $0.isSecureTextEntry = true
                            $0.placeholder = Strings.password
                        }
                    }
                    confirmation = { [weak alert] in
                        guard authorizeConfirmation() else { return nil }
                        return requestsPassword ? alert?.textFields?.first?.text : ""
                    }
                    alert.addAction(UIAlertAction(title: retry ? Strings.tryAgain : Strings.ok, style: .default) { [weak self] _ in
                        self?.confirm()
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

        func confirm() {
            guard !isFinishing, continuation != nil else { return }
            let confirmation = confirmation
            self.confirmation = nil
            finish(confirmation?())
        }

        func finish(_ value: String?) {
            guard !isFinishing, continuation != nil else { return }
            isFinishing = true
            confirmation = nil
            pendingResult = isCancelled ? nil : value
            alert?.textFields?.forEach { $0.clearSecretDraft() }
            guard let alert else {
                resolve()
                return
            }
            dismiss(alert, !isCancelled) { [self] in resolve() }
        }

        private func resolve() {
            let continuation = continuation
            let value = pendingResult
            pendingResult = nil
            self.continuation = nil
            alert = nil
            continuation?.resume(returning: isCancelled ? nil : value)
        }

        func cancel() {
            isCancelled = true
            pendingResult = nil
            finish(nil)
        }

    }
}
