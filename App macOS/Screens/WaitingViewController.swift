// ∅ 2026 lil org

import Cocoa

class WaitingViewController: NSViewController {
    
    private var reason = ""
    private var closeCompletion: (() -> Void)?
    
    @IBOutlet weak var progressIndicator: NSProgressIndicator!
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var okButton: NSButton!

    static func with(
        reason: String,
        closeCompletion: @escaping () -> Void
    ) -> WaitingViewController {
        let controller = instantiate(WaitingViewController.self)
        controller.reason = reason
        controller.closeCompletion = closeCompletion
        return controller
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        titleLabel.stringValue = reason
        okButton.title = Strings.ok
        progressIndicator.startAnimation(nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.delegate = self
    }

    func update(reason: String) {
        self.reason = reason
        if isViewLoaded {
            titleLabel.stringValue = reason
        }
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        Window.closeWindow(idToClose: view.window?.windowNumber)
    }
    
}

extension WaitingViewController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        closeCompletion?()
    }

}
