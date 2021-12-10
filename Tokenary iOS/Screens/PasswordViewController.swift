// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

class PasswordViewController: UIViewController {
    
    enum Mode {
        case create, repeatAfterCreate, enter
    }
    
    private let keychain = Keychain.shared
    private var mode = Mode.create
    var passwordToRepeat: String?
    
    @IBOutlet weak var passwordTextField: UITextField! {
        didSet {
            passwordTextField.delegate = self
            passwordTextField.addTarget(self, action: #selector(textFieldChanged), for: .editingChanged)
        }
    }
    
    @IBOutlet weak var initialOverlayView: UIView!
    @IBOutlet weak var okButton: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.backButtonDisplayMode = .minimal
        navigationController?.setNavigationBarHidden(true, animated: false)
        
        if passwordToRepeat != nil {
            switchToMode(.repeatAfterCreate)
        } else if keychain.password != nil {
            switchToMode(.enter)
        } else {
            switchToMode(.create)
        }
    }
    
    func switchToMode(_ mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            navigationItem.title = Strings.createPassword
        case .repeatAfterCreate:
            navigationItem.title = Strings.repeatPassword
        case .enter:
            navigationItem.title = Strings.enterPassword
        }
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        proceedIfPossible()
    }
    
    @objc private func textFieldChanged() {
        let isEnabled = passwordTextField.text?.isOkAsPassword == true
        if okButton.isEnabled != isEnabled {
            okButton.isEnabled = isEnabled
        }
    }
    
    private func proceedIfPossible() {
        switch mode {
        case .create:
            let passwordViewController = instantiate(PasswordViewController.self, from: .main)
            passwordViewController.passwordToRepeat = passwordTextField.text
            navigationController?.pushViewController(passwordViewController, animated: true)
        case .repeatAfterCreate:
            if let password = passwordTextField.text, !password.isEmpty, password == passwordToRepeat {
                keychain.save(password: password)
                showAccountsList()
            } else {
                showMessageAlert(text: Strings.passwordDoesNotMatch)
            }
        case .enter:
            if passwordTextField.text == keychain.password {
                showAccountsList()
            } else {
                showMessageAlert(text: Strings.passwordDoesNotMatch)
            }
        }
    }
    
    private func showAccountsList() {
        let accountsList = instantiate(AccountsListViewController.self, from: .main)
        UIApplication.shared.replaceRootViewController(with: accountsList.inNavigationController)
    }
    
}

extension PasswordViewController: UITextFieldDelegate {
    
    func textFieldDidBeginEditing(_ textField: UITextField) {
        textFieldChanged()
    }
    
    func textFieldDidEndEditing(_ textField: UITextField, reason: UITextField.DidEndEditingReason) {
        textFieldChanged()
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if passwordTextField.text?.isOkAsPassword == true {
            proceedIfPossible()
        }
        return true
    }
    
}
