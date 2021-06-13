// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class ErrorViewController: NSViewController {
    
    static func withMessage(_ message: String) -> ErrorViewController {
        let new = instantiate(ErrorViewController.self)
        new.message = message
        return new
    }
    
    private var message = ""
    
    @IBOutlet weak var titleLabel: NSTextField!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // TODO: show message text
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        Window.closeAll()
        Window.activateSafari()
    }
    
}
