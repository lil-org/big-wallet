// ∅ 2026 lil org

import Cocoa

class WaitingViewController: NSViewController {
    
    private var reason = ""
    
    @IBOutlet weak var progressIndicator: NSProgressIndicator!
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var okButton: NSButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        titleLabel.stringValue = reason
        okButton.title = Strings.ok
        progressIndicator.startAnimation(nil)
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        Window.closeWindowAndActivateNext(idToClose: view.window?.windowNumber, specificBrowser: nil)
    }
    
}
