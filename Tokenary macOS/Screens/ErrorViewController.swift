// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa

class ErrorViewController: NSViewController {
    
    static func withMessage(_ message: String) -> ErrorViewController {
        let new = instantiate(ErrorViewController.self)
        new.message = message
        return new
    }
    
    private var message = ""
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var messageLabel: NSTextField!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        messageLabel.stringValue = message
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        Window.closeAllAndActivateBrowser(force: nil)
    }
    
}
