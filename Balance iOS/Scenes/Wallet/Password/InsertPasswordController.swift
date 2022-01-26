import UIKit
import SparrowKit
import NativeUIKit
import SFSymbols
import SPIndicator

class InsertPasswordController: NativeHeaderTextFieldController, UITextFieldDelegate, OnboardingChildInterface {
    
    var onboardingManagerDelegate: OnboardingManagerDelegate?

    internal var action: ((Bool)->Void)
    
    let actionToolbarView = NativeLargeActionToolBarView().do {
        $0.actionButton.set(
            title: "Sign In",
            icon: UIImage(SFSymbol.checkmark.circleFill),
            colorise: .init(content: .custom(.white), background: .tint)
        )
        $0.footerLabel.text = "Requerid for continue with your action."
    }
    
    init(action: @escaping ((Bool)->Void)) {
        self.action = action
        super.init(
            image: .init(.lock.fill),
            title: "Current Password",
            subtitle: "You password shoud be somewhere in private plaece."
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        footerView.label.text = "Minimum 5 characters for safety."
        
        if let navigationController = self.navigationController as? NativeNavigationController {
            navigationController.mimicrateToolBarView = actionToolbarView
        }
        
        actionToolbarView.actionButton.addAction(.init(handler: { _ in
            self.checkPassword()
        }), for: .touchUpInside)
        
        textField.clearButtonMode = .whileEditing
        textField.placeholder = "Your Password"
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
        
        navigationItem.rightBarButtonItem = .init(systemItem: .close, primaryAction: .init(handler: { _ in
            self.action(false)
            self.dismissAnimated()
        }), menu: nil)
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
    
    internal func checkPassword() {
        guard let text = textField.text else { return }
        if text.count < 5 { return }
        let keychain = Keychain.shared
        if keychain.password == text {
            if onboardingManagerDelegate == nil {
                self.dismiss(animated: true, completion: {
                    self.action(true)
                    self.onboardingManagerDelegate?.onboardingActionComplete(for: self)
                })
            } else {
                self.onboardingManagerDelegate?.onboardingActionComplete(for: self)
            }
        } else {
            SPIndicator.present(title: "Wrong Password", preset: .error)
            textField.text = nil
            textField.becomeFirstResponder()
        }
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        checkPassword()
        return true
    }
}
