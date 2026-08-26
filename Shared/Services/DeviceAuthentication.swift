// ∅ 2026 lil org

import Foundation
import LocalAuthentication

struct DeviceAuthentication {

    enum Outcome: Equatable {
        case succeeded
        case failed
        case interactionUnavailable
    }

    static var canUseBiometrics: Bool {
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static func attemptBiometrics(
        reason: String,
        completion: @escaping (Outcome) -> Void
    ) {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            DispatchQueue.main.async { completion(.failed) }
            return
        }
#if os(macOS)
        let evaluationPolicy = LAPolicy.deviceOwnerAuthentication
#else
        let evaluationPolicy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
#endif
        context.localizedCancelTitle = Strings.cancel
        context.evaluatePolicy(evaluationPolicy, localizedReason: reason) { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(.succeeded)
                } else if (error as? LAError)?.code == .notInteractive {
                    completion(.interactionUnavailable)
                } else {
                    completion(.failed)
                }
            }
        }
    }

    static func verify(password: String) -> Bool {
        return password == Keychain.shared.password
    }

}
