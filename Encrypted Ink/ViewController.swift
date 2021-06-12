// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class ViewController: NSViewController {

    private var connectivity: NearbyConnectivity?
    
    @IBOutlet weak var label: NSTextField!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        label.stringValue = "yo"
        connectivity = NearbyConnectivity(delegate: self)
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

}

extension ViewController: NearbyConnectivityDelegate {
    
    func didFind(link: String) {
        label.stringValue = link
    }
    
}
