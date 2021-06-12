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
        // TODO: open accounts list
        
        WalletConnect.shared.connect(link: globalLink, address: "0xCf60CC6E4AD79187E7eBF62e0c21ae3a343180B2") { connected in
            // TODO: close here
            // use connected value
        }
        
        // TODO: show spinner
        Window.closeAll()
        Window.activateSafari()
    }
    
}

extension ImportViewController: NSTextFieldDelegate {
    
    func controlTextDidChange(_ obj: Notification) {
        okButton.isEnabled = AccountsService.validateAccountKey(textField.stringValue)
    }
    
}
