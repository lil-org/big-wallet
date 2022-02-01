import UIKit
import SFSymbols
import SPIndicator
import SparrowKit
import Constants
import SPAlert

class AuthController: PasswordController, UIAdaptivePresentationControllerDelegate {
    
    var action: ((Bool) -> Void)?
    
    init() {
        super.init(
            title: "Current Password",
            subtitle: "You password shoud be somewhere in private plaece.",
            action: "Sign In",
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
        navigationController?.presentationController?.delegate = self
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
