// Copyright © 2021 Tokenary. All rights reserved.

import LocalAuthentication

struct LocalAuthentication {
    
    static func attempt(reason: String, completion: @escaping ((Bool) -> Void)) {
        let context = LAContext()
        var error: NSError?
        let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
        let canDoLocalAuthentication = context.canEvaluatePolicy(policy, error: &error)
        if canDoLocalAuthentication {
            context.localizedCancelTitle = Strings.cancel
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                DispatchQueue.main.async {
                    completion(success)
                }
            }
        } else {
            completion(false)
        }
    }
    
}
