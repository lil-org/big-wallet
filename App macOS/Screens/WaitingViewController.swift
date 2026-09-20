// ∅ 2026 lil org

import Cocoa

class WaitingViewController: NSViewController {
    
    private var reason = ""
    private var isWorking = true
    private var closeCompletion: (() -> Void)?
    private var retryAction: (() -> Void)?
    
    @IBOutlet weak var progressIndicator: NSProgressIndicator!
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var okButton: NSButton!

    static func with(
        reason: String,
        isWorking: Bool = true,
        retryAction: (() -> Void)? = nil,
        closeCompletion: @escaping () -> Void
    ) -> WaitingViewController {
        let controller = instantiate(WaitingViewController.self)
        controller.reason = reason
        controller.isWorking = isWorking
        controller.retryAction = retryAction
        controller.closeCompletion = closeCompletion
        return controller
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        update(reason: reason, isWorking: isWorking, retryAction: retryAction)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.delegate = self
    }

    func update(reason: String, isWorking: Bool = true, retryAction: (() -> Void)? = nil) {
        self.reason = reason
        self.isWorking = isWorking
        self.retryAction = retryAction
        guard isViewLoaded else { return }
        titleLabel.stringValue = reason
        okButton.title = retryAction == nil ? Strings.ok : Strings.tryAgain
        progressIndicator.isHidden = !isWorking || retryAction != nil
        if isWorking && retryAction == nil { progressIndicator.startAnimation(nil) }
        else { progressIndicator.stopAnimation(nil) }
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        if let retryAction { retryAction() }
        else { Window.closeWindow(idToClose: view.window?.windowNumber) }
    }
    
}

extension WaitingViewController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        closeCompletion?()
    }

}
