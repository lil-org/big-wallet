// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class WelcomeViewController: NSViewController {
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var messageLabel: NSTextField!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        messageLabel.stringValue = "Sign crypto transactions.\n\nIn any browser.\n\nOn any website."
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        // TODO: go to password creation
    }
    
}
