// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class ImportViewController: NSViewController {
    
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
        AccountsService.addAccount(privateKey: textField.stringValue)
        
        // TODO: open accounts list
        
        WalletConnect.shared.connect(link: globalLink, address: "0xCf60CC6E4AD79187E7eBF62e0c21ae3a343180B2") { connected in
            // TODO: close here
            // use connected value
        }
        
        showAccountsList()
        
        // TODO: show spinner
//        Window.closeAll()
//        Window.activateSafari()
    }
 
    private func showAccountsList() {
        if let accounts = storyboard?.instantiateController(withIdentifier: "AccountsListViewController") as? AccountsListViewController {
            view.window?.contentViewController = accounts
        }
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        showAccountsList()
        // TODO: in some cases should close the window
    }
    
}

extension ImportViewController: NSTextFieldDelegate {
    
    func controlTextDidChange(_ obj: Notification) {
        okButton.isEnabled = AccountsService.validateAccountKey(textField.stringValue)
    }
    
}
