// ∅ 2026 lil org

import Foundation
import LocalAuthentication

struct DeviceAuthentication {
    enum Outcome: Equatable, Sendable {
        case succeeded
        case failed
        case interactionUnavailable
    }

    static var canUseBiometrics: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    @MainActor
    static func attemptBiometrics(reason: String) async -> Outcome {
        guard !Task.isCancelled else { return .failed }
        let attempt = AuthenticationAttempt()
        return await withTaskCancellationHandler {
            let outcome = await attempt.evaluate(reason: reason)
            return Task.isCancelled ? .failed : outcome
        } onCancel: {
            Task { @MainActor in attempt.cancel() }
        }
    }

    static func verify(password: String) -> Bool {
        password == Keychain.shared.password
    }

    @MainActor
    private final class AuthenticationAttempt {
        private let context = LAContext()

        func evaluate(reason: String) async -> Outcome {
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return .failed }
#if os(macOS)
            let policy = LAPolicy.deviceOwnerAuthentication
#else
            let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
#endif
            context.localizedCancelTitle = Strings.cancel
            return await withCheckedContinuation { continuation in
                context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                    if success {
                        continuation.resume(returning: .succeeded)
                    } else if (error as? LAError)?.code == .notInteractive {
                        continuation.resume(returning: .interactionUnavailable)
                    } else {
                        continuation.resume(returning: .failed)
                    }
                }
            }
        }

        func cancel() {
            context.invalidate()
        }
    }
}
