// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

class PasswordViewController: UIViewController {
    
    @IBOutlet weak var passwordTextField: UITextField! {
        didSet {
            passwordTextField.delegate = self
            passwordTextField.addTarget(self, action: #selector(textFieldChanged), for: .editingChanged)
        }
    }
    
    @IBOutlet weak var okButton: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "Enter password"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        passwordTextField.becomeFirstResponder()
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
        showAccountsList()
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
        proceedIfPossible()
        return true
    }
    
}
