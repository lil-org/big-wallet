// ∅ 2025 lil org

import Cocoa

class WelcomeViewController: NSViewController {
    
    static func new(completion: ((Bool) -> Void)?) -> WelcomeViewController {
        let new = instantiate(WelcomeViewController.self)
        new.completion = completion
        return new
    }
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var messageLabel: NSTextField!
    @IBOutlet weak var getStartedButton: NSButton!
    
    private var completion: ((Bool) -> Void)?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        titleLabel.stringValue = Strings.bigWallet
        messageLabel.stringValue = Strings.welcomeScreenText
        getStartedButton.title = Strings.getStarted
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        let passwordViewController = PasswordViewController.with(mode: .create, completion: completion)
        view.window?.contentViewController = passwordViewController
    }
    
}
