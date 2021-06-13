// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class ApproveViewController: NSViewController {
    
    @IBOutlet weak var titleLabel: NSTextField!
    
    var completion: ((Bool) -> Void)!
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        completion(true)
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        completion(false)
    }
    
}
