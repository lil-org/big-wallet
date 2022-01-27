import UIKit
import SFSymbols
import SPIndicator

class AuthController: PasswordController, UIAdaptivePresentationControllerDelegate {
    
    var action: ((Bool) -> Void)?
    
    init() {
        super.init(
            title: "Current Password",
            subtitle: "You password shoud be somewhere in private plaece.",
            action: "Sign In",
            actionIcon: UIImage(SFSymbol.checkmark.circleFill),
            textFieldFooter: "Minimum 5 characters for safety.",
            toolBarFooter: "Requerid for continue with your action.",
            placeholder: "Your Password"
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.presentationController?.delegate = self
    }
    
    override func askProcessPassword(_ password: String) {
        let correctPassword = Keychain.shared.password == password
        if correctPassword {
            self.dismiss(animated: true, completion: {
                self.action?(true)
            })
        } else {
            SPIndicator.present(title: "Wrong Password", preset: .error)
            self.textField.text = nil
        }
    }
    
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        return false
    }
}
