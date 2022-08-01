// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa

class WaitingViewController: NSViewController {
    
    static func withReason(_ reason: String) -> WaitingViewController {
        let new = instantiate(WaitingViewController.self)
        new.reason = reason
        return new
    }
    
    private var reason = ""
    
    @IBOutlet weak var progressIndicator: NSProgressIndicator!
    @IBOutlet weak var titleLabel: NSTextField!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        titleLabel.stringValue = reason
        progressIndicator.startAnimation(nil)
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        Window.closeWindowAndActivateNext(idToClose: view.window?.windowNumber, specificBrowser: nil)
    }
    
}
