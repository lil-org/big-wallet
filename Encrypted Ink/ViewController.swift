// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class ViewController: NSViewController {
    
    @IBOutlet weak var label: NSTextField!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        label.stringValue = "yo"
    }

}
