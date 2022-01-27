import UIKit
import SparrowKit
import NativeUIKit
import SFSymbols
import SPPermissions
import SPPermissionsFaceID
import SPAlert

class ChangePassword: PasswordController {
    
    init() {
        super.init(
            title: "New Password",
            subtitle: "We change password for each imported wallet.",
            action: "Set Password",
            actionIcon: UIImage(SFSymbol.checkmark.circleFill),
            textFieldFooter: "Minimum 5 characters for safety.",
            toolBarFooter: "It locked only app and don't make any special password to wallet.",
            placeholder: "New Password"
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func askProcessPassword(_ password: String) {
        let keychain = Keychain.shared
        let oldPassword = keychain.password
        let newPassword = password
        keychain.save(password: newPassword)
        if let oldPassword = oldPassword {
            // Shoud update all wallets to new password
            for wallet in WalletsManager.shared.wallets {
                do {
                    try? WalletsManager.shared.update(wallet: wallet, password: oldPassword, newPassword: newPassword)
                }
            }
        }
        self.dismissAnimated()
        SPAlert.present(title: "Password Updated", message: nil, preset: .done, completion: nil)
        /*
         guard let text = textField.text else { return }
         let keychain = Keychain.shared
         let oldPassword = keychain.password
         let newPassword = text
         keychain.save(password: newPassword)
         if let oldPassword = oldPassword {
             // Shoud update all wallets to new password
             for wallet in WalletsManager.shared.wallets {
                 do {
                     try? WalletsManager.shared.update(wallet: wallet, password: oldPassword, newPassword: newPassword)
                 }
             }
         }
         let completeAction: (()->Void) = {
             if self.onboardingManagerDelegate != nil {
                 self.onboardingManagerDelegate?.onboardingActionComplete(for: self)
             } else {
                 
             }
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
                     self.onboardingManagerDelegate?.onboardingActionComplete(for: self)
                 }
                 present(alertController)
             } else {
                 completeAction()
             }
         }
         */
    }
}
