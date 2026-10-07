// ∅ 2026 lil org

import Cocoa

final class WelcomeViewController: NSViewController {
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var messageLabel: NSTextField!
    @IBOutlet weak var getStartedButton: NSButton!

    private var onGetStarted: (() -> Void)?

    static func new(onGetStarted: @escaping () -> Void) -> WelcomeViewController {
        let controller = instantiate(WelcomeViewController.self)
        controller.onGetStarted = onGetStarted
        return controller
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        titleLabel.stringValue = Strings.bigWallet
        messageLabel.stringValue = Strings.welcomeScreenText
        getStartedButton.title = Strings.getStarted
        getStartedButton.isEnabled = onGetStarted != nil
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        onGetStarted?()
    }

    func retire() {
        onGetStarted = nil
        if isViewLoaded { getStartedButton.isEnabled = false }
    }
}
