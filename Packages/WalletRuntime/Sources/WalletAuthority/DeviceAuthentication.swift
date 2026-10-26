import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import Foundation
import LocalAuthentication

struct DeviceAuthentication {
    static var canUseBiometrics: Bool {
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    @MainActor
    static func attemptBiometrics(reason: String) async -> WalletAuthenticationOutcome {
        guard !Task.isCancelled else { return .failed }
        let attempt = AuthenticationAttempt()
        return await withTaskCancellationHandler {
            let outcome = await attempt.evaluate(reason: reason)
            return Task.isCancelled ? .failed : outcome
        } onCancel: {
            Task { @MainActor in attempt.cancel() }
        }
    }

    @MainActor
    private final class AuthenticationAttempt {
        private let context = LAContext()

        func evaluate(reason: String) async -> WalletAuthenticationOutcome {
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return .failed }
#if os(macOS)
            let policy = LAPolicy.deviceOwnerAuthentication
#else
            let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
#endif
            context.localizedCancelTitle = AuthorityStrings.cancel
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

