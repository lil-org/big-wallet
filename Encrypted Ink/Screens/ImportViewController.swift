// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class ImportViewController: NSViewController {
    
    var onSelectedAccount: ((Account) -> Void)?
    
    @IBOutlet weak var textField: NSTextField! {
        didSet {
            textField.delegate = self
        }
    }
    @IBOutlet weak var okButton: NSButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        if let account = AccountsService.addAccount(privateKey: textField.stringValue),
           let onSelectedAccount = onSelectedAccount {
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
        okButton.isEnabled = AccountsService.validateAccountKey(textField.stringValue)
    }
    
}
