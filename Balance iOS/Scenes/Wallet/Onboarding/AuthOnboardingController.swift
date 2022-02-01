import UIKit
import SFSymbols
import SparrowKit
import Constants
import SPAlert
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
            toolBarFooter: nil,
            placeholder: "Your Password"
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        actionToolbarView.secondActionButton.setTitle("Reset Existing Wallet")
        actionToolbarView.secondActionButton.addAction(.init(handler: { _ in
            WalletsManager.startDestroyProcess(on: self, sourceView: self.actionToolbarView.secondActionButton) { destroyed in
                if destroyed {
                    guard let parent = self.presentingViewController else { return }
                    self.dismiss(animated: true, completion: {
                        Presenter.App.showOnboarding(on: parent, afterAction: {
                            Presenter.Crypto.showWalletOnboarding(on: parent)
                            Flags.seen_tutorial = true
                        })
                        delay(0.1, closure: {
                            SPAlert.present(title: "Wallet was reseted. Let's reconfigure it", message: nil, preset: .done, completion:  nil)
                        })
                    })
                }
            }
        }), for: .touchUpInside)
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
