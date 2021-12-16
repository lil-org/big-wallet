// Copyright © 2021 Tokenary. All rights reserved.

import UIKit
import LocalAuthentication

struct LocalAuthentication {
    
    static func attempt(reason: String, presentPasswordAlertFrom from: UIViewController?, passwordReason: String?, completion: @escaping ((Bool) -> Void)) {
        let context = LAContext()
        var error: NSError?
        let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
        let canDoLocalAuthentication = context.canEvaluatePolicy(policy, error: &error)
        
        func tryWithPassword() {
            from?.showPasswordAlert(title: Strings.enterPassword, message: passwordReason) { [weak from] password in
                if let password = password {
                    if password == Keychain.shared.password {
                        completion(true)
                    } else {
                        from?.showMessageAlert(text: Strings.passwordDoesNotMatch) {
                            completion(false)
                        }
                    }
                } else {
                    completion(false)
                }
            }
        }
        
        if canDoLocalAuthentication {
            context.localizedCancelTitle = Strings.cancel
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                DispatchQueue.main.async {
                    if success {
                        completion(true)
                    } else if from != nil {
                        tryWithPassword()
                    } else {
                        completion(false)
                    }
                }
            }
        } else if from != nil {
            tryWithPassword()
        } else {
            completion(false)
        }
    }
    
}
