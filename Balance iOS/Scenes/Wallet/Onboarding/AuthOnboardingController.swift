import UIKit
import SFSymbols
import SPIndicator

class AuthOnboardingController: PasswordController, OnboardingChildInterface {
    
    var onboardingManagerDelegate: OnboardingManagerDelegate?
    
    init() {
        super.init(
            title: "Unlock Wallet",
            subtitle: "You password shoud be somewhere in private plaece. After login we propose import your wallets.",
            action: "Unlock Wallet",
            actionIcon: UIImage(SFSymbol.checkmark.circleFill),
            textFieldFooter: "Minimum 5 characters for safety.",
            toolBarFooter: "Requerid for continue with your action.",
            placeholder: "Your Password"
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func askProcessPassword(_ password: String) {
        if Keychain.shared.password == password {
            onboardingManagerDelegate?.onboardingActionComplete(for: self)
        } else {
            SPIndicator.present(title: "Wrong Password", preset: .error)
            self.textField.text = nil
        }
    }
}
