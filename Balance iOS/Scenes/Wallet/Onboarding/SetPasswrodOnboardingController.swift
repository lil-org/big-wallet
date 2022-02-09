import UIKit
import SparrowKit
import NativeUIKit
import SPSafeSymbols
import SPPermissions
import SPPermissionsFaceID
import SPAlert

class SetPasswrodOnboardingController: PasswordController, OnboardingChildInterface {
    
    var onboardingManagerDelegate: OnboardingManagerDelegate?
    
    init() {
        super.init(
            title: "Set New Password",
            subtitle: "You will have access to wallets and app by this password.",
            action: "Set Password",
            actionIcon: UIImage(SPSafeSymbol.checkmark.circleFill),
            textFieldFooter: "Minimum 5 characters for safety.",
            toolBarFooter: "It locked only app and don't make any special password to wallet.",
            placeholder: "Set Password"
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func askProcessPassword(_ password: String) {
        let keychain = Keychain.shared
        keychain.save(password: password)
        
        let completeAction: (()->Void) = {
            self.onboardingManagerDelegate?.onboardingActionComplete(for: self)
        }
        
        if SPPermissions.Permission.faceID.authorized {
            completeAction()
        } else {
            let supported = SPPermissions.Permission.faceID.status == .notSupported
            if SPPermissions.Permission.faceID.status == .notDetermined && supported {
                let alertController = UIAlertController(title: "Do you want use FaceID?", message: "You can use faster entry by biometric auth process.", preferredStyle: .alert)
                alertController.addAction(title: "Use FaceID", style: .default) { action in
                    SPPermissions.Permission.faceID.request {
                        completeAction()
                    }
                }
                alertController.addAction(title: "Don't use", style: .cancel) { _ in
                    completeAction()
                }
                present(alertController)
            } else {
                completeAction()
            }
        }
    }
}
