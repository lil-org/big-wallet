// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class ImportViewController: NSViewController {
    
    private let walletsManager = WalletsManager.shared
    var onSelectedWallet: ((Int, InkWallet) -> Void)?
    private var inputValidationResult = WalletsManager.InputValidationResult.invalid
    
    @IBOutlet weak var textField: NSTextField! {
        didSet {
            textField.delegate = self
            textField.placeholderString = "Options:\n\n• Ethereum Private Key\n• Secret Words\n• Keystore"
        }
    }
    @IBOutlet weak var okButton: NSButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        if inputValidationResult == .requiresPassword {
            showPasswordAlert()
        } else {
            importWith(input: textField.stringValue, password: nil)
        }
    }
 
    private func showPasswordAlert() {
        let passwordAlert = PasswordAlert(title: "Enter keystore password.")
        DispatchQueue.main.async {
            passwordAlert.passwordTextField.becomeFirstResponder()
        }
        
        if passwordAlert.runModal() == .alertFirstButtonReturn {
            importWith(input: textField.stringValue, password: passwordAlert.passwordTextField.stringValue)
        }
    }
    
    private func importWith(input: String, password: String?) {
        do {
            let wallet = try walletsManager.addWallet(input: input, inputPassword: password)
            showAccountsList(newWalletId: wallet.id)
        } catch {
            Alert.showWithMessage("Failed to import account", style: .critical)
        }
    }
    
    private func showAccountsList(newWalletId: String?) {
        let accountsListViewController = instantiate(AccountsListViewController.self)
        accountsListViewController.onSelectedWallet = onSelectedWallet
        if let newWalletId = newWalletId {
            accountsListViewController.newWalletIds = [newWalletId]
        }
        view.window?.contentViewController = accountsListViewController
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        showAccountsList(newWalletId: nil)
    }
    
}

extension ImportViewController: NSTextFieldDelegate {
    
    func controlTextDidChange(_ obj: Notification) {
        inputValidationResult = walletsManager.validateWalletInput(textField.stringValue)
        okButton.isEnabled = inputValidationResult != .invalid
    }
    
}
