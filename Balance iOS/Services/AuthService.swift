import UIKit
import NativeUIKit
enum AuthService {
    
    static func auth(on viewController: UIViewController, completion: @escaping ((Bool) -> Void)) {
        LocalAuthentication.attempt(reason: Strings.enterTokenary, presentPasswordAlertFrom: nil, passwordReason: nil) { success in
            if success {
                completion(success)
            } else {
                Presenter.Crypto.Password.showPassowrdInsert(action: { success in
                    if success {
                        completion(success)
                    } else {
                        completion(false)
                    }
                }, on: viewController)
            }
        }
    }
}
