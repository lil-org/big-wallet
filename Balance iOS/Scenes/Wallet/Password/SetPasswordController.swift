import UIKit
import SparrowKit
import NativeUIKit
import SFSymbols
import SPPermissions
import SPPermissionsFaceID
import SPAlert

class SetPasswordController: NativeHeaderTextFieldController, OnboardingChildInterface, UITextFieldDelegate {
    
    var onboardingManagerDelegate: OnboardingManagerDelegate?
    
    let actionToolbarView = NativeLargeActionToolBarView().do {
        $0.actionButton.set(
            title: "Save Password",
            icon: UIImage(SFSymbol.checkmark.circleFill),
            colorise: .init(content: .custom(.white), background: .tint)
        )
        $0.footerLabel.text = "It locked only app and don't make any special password to wallet."
    }
    
    init() {
        super.init(
            image: .init(.lock.fill),
            title: "New Password",
            subtitle: "You can have access all data with this passphrase."
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        footerView.label.text = "Set minimum 5 characters for safety."
        
        if let navigationController = self.navigationController as? NativeNavigationController {
            navigationController.mimicrateToolBarView = actionToolbarView
        }
        
        actionToolbarView.actionButton.addAction(.init(handler: { _ in
            self.saveAction()
        }), for: .touchUpInside)
        
        textField.clearButtonMode = .whileEditing
        textField.placeholder = "Password"
        textField.delegate = self
        textField.keyboardType = .default
        textField.isSecureTextEntry = true
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.addAction(.init(handler: { [weak self] (action) in
            guard let self = self else { return }
            self.updateAvabilityInterface()
        }), for: .editingChanged)
        
        self.updateAvabilityInterface()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        delay(0.7, closure: {
            self.textField.becomeFirstResponder()
        })
    }
    
    internal var insertedValidPassword: Bool {
        guard let text = textField.text else { return false }
        if text.isEmpty { return false }
        if text.count < 5 { return false }
        return true
    }
    
    internal func updateAvabilityInterface() {
        navigationItem.rightBarButtonItem?.isEnabled = insertedValidPassword
        actionToolbarView.actionButton.isEnabled = insertedValidPassword
    }
    
    internal func saveAction() {
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
                self.dismissAnimated()
                SPAlert.present(title: "Password Updated", message: nil, preset: .done, completion: nil)
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
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
