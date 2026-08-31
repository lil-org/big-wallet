// ∅ 2026 lil org

import UIKit

struct LocalAuthentication {

    static func attempt(reason: String, presentPasswordAlertFrom from: UIViewController?, passwordReason: String?, completion: @escaping ((Bool) -> Void)) {
        func tryWithPassword() {
            from?.showPasswordAlert(title: Strings.enterPassword, message: passwordReason) { [weak from] password in
                if let password = password {
                    if DeviceAuthentication.verify(password: password) {
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

        DeviceAuthentication.attemptBiometrics(reason: reason) { outcome in
            if outcome == .succeeded {
                completion(true)
            } else if from != nil {
                tryWithPassword()
            } else {
                completion(false)
            }
        }
    }

}
