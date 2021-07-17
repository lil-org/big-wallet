// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class ImportViewController: NSViewController {
    
    private let accountsService = AccountsService.shared
    var onSelectedAccount: ((Account) -> Void)?
    
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
        let account = accountsService.addAccount(input: textField.stringValue)
        if let account = account, accountsService.getAccounts().count == 1, let onSelectedAccount = onSelectedAccount {
            onSelectedAccount(account)
        } else {
            showAccountsList()
        }
    }
 
    private func showAccountsList() {
        let accountsListViewController = instantiate(AccountsListViewController.self)
        accountsListViewController.onSelectedAccount = onSelectedAccount
        view.window?.contentViewController = accountsListViewController
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        showAccountsList()
    }
    
}

extension ImportViewController: NSTextFieldDelegate {
    
    func controlTextDidChange(_ obj: Notification) {
        okButton.isEnabled = accountsService.validateAccountInput(textField.stringValue)
    }
    
}
