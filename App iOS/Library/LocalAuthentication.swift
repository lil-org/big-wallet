// ∅ 2026 lil org

import UIKit

@MainActor
struct LocalAuthentication {
    static func attempt(reason: String, presentPasswordAlertFrom presenter: @escaping @MainActor @Sendable () -> UIViewController?, passwordReason: String?) async -> Bool {
        let outcome = await DeviceAuthentication.attemptBiometrics(reason: reason)
        guard !Task.isCancelled else { return false }
        if outcome == .succeeded { return true }
        let prompt = AlertRequest()
        guard let password = await prompt.present(from: presenter, title: Strings.enterPassword, message: passwordReason, requestsPassword: true),
              !Task.isCancelled else { return false }
        if DeviceAuthentication.verify(password: password) { return true }
        _ = await AlertRequest().present(from: presenter, title: Strings.passwordDoesNotMatch, message: nil, requestsPassword: false)
        return false
    }

    @MainActor
    private final class AlertRequest {
        private var continuation: CheckedContinuation<String?, Never>?
        private var alert: UIAlertController?

        func present(from presenter: @escaping @MainActor @Sendable () -> UIViewController?, title: String, message: String?, requestsPassword: Bool) async -> String? {
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
                    alert.addAction(UIAlertAction(title: Strings.ok, style: .default) { [weak self, weak alert] _ in
                        self?.finish(requestsPassword ? alert?.textFields?.first?.text : "")
                    })
                    if requestsPassword {
                        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel) { [weak self] _ in
                            self?.finish(nil)
                        })
                    }
                    controller.present(alert, animated: true)
                }
            } onCancel: {
                Task { @MainActor in self.cancel() }
            }
        }

        private func finish(_ value: String?) {
            let continuation = continuation
            self.continuation = nil
            alert = nil
            continuation?.resume(returning: value)
        }

        private func cancel() {
            alert?.dismiss(animated: false)
            finish(nil)
        }
    }
}
