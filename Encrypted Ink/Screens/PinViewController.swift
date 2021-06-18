// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class PinViewController: NSViewController {
    
    enum Mode {
        case create, enter
    }
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var codeTextField: NSSecureTextField!
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        
    }
    
}
