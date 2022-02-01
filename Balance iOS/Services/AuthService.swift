import UIKit
import NativeUIKit

enum AuthService {
    
    static func auth(cancelble: Bool, on viewController: UIViewController, completion: @escaping ((Bool) -> Void)) {
        completion(true)
        /*LocalAuthentication.attempt(reason: Strings.enterTokenary, presentPasswordAlertFrom: nil, passwordReason: nil) { success in
            if success {
                completion(success)
            } else {
                Presenter.Crypto.auth(cancelble: cancelble, action: { result in
                    completion(result)
                }, on: viewController)
            }
        }*/
    }
}
