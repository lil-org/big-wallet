// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa

class WelcomeViewController: NSViewController {
    
    static func new(completion: ((Bool) -> Void)?) -> WelcomeViewController {
        let new = instantiate(WelcomeViewController.self)
        new.completion = completion
        return new
    }
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var messageLabel: NSTextField!
    
    private var completion: ((Bool) -> Void)?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        messageLabel.stringValue = Strings.welcomeScreenText
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        let passwordViewController = PasswordViewController.with(mode: .create, completion: completion)
        view.window?.contentViewController = passwordViewController
    }
    
}
