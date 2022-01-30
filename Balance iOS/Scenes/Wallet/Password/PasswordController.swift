import UIKit
import SparrowKit
import NativeUIKit
import SFSymbols
import SPPermissions
import SPPermissionsFaceID
import SPAlert

class PasswordController: NativeHeaderTextFieldController, UITextFieldDelegate {
    
    // MARK: - Views
    
    let actionToolbarView = NativeLargeSmallActionToolBarView()
    
    // MARK: - Init
    
    init(title: String, subtitle: String, action: String, actionIcon: UIImage?, textFieldFooter: String, toolBarFooter: String?, placeholder: String) {
        super.init(image: .init(.lock.fill), title: title, subtitle: subtitle)
        actionToolbarView.actionButton.set(
            title: action,
            icon: actionIcon,
            colorise: .init(content: .custom(.white), background: .tint)
        )
        actionToolbarView.footerLabel.text = toolBarFooter
        footerView.label.text = textFieldFooter
        textField.placeholder = placeholder
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if let navigationController = self.navigationController as? NativeNavigationController {
            navigationController.mimicrateToolBarView = actionToolbarView
        }
        
        actionToolbarView.actionButton.addAction(.init(handler: { _ in
            guard self.insertedValidPassword else { return }
            guard let text = self.textField.text else { return }
            self.askProcessPassword(text)
        }), for: .touchUpInside)
        
        textField.clearButtonMode = .whileEditing
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
    
    // MARK: - For Ovveride
    
    internal func askProcessPassword(_ password: String) {}
    
    // MARK: - UITextFieldDelegate
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        guard insertedValidPassword else { return true }
        guard let text = textField.text else { return true }
        askProcessPassword(text)
        return true
    }
    
    // MARK: - Private
    
    internal var insertedValidPassword: Bool {
        guard let text = textField.text else { return false }
        if text.isEmpty { return false }
        if text.count < 5 { return false }
        return true
    }
    
    internal func updateAvabilityInterface() {
        actionToolbarView.actionButton.isEnabled = insertedValidPassword
    }
}
