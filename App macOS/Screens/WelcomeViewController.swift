// ∅ 2026 lil org

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
    private var didCallCompletion = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        titleLabel.stringValue = Strings.bigWallet
        messageLabel.stringValue = Strings.welcomeScreenText
        getStartedButton.title = Strings.getStarted
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil)
        DispatchQueue.main.async { [weak self] in
            self?.walletsChanged()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        NotificationCenter.default.removeObserver(self, name: .walletsChanged, object: nil)
        let passwordViewController = PasswordViewController.with(mode: .create, completion: completion)
        view.window?.contentViewController = passwordViewController
    }

    @objc private func walletsChanged() {
        guard Keychain.shared.password != nil else { return }
        callCompletion(result: false)
    }

    private func callCompletion(result: Bool) {
        guard !didCallCompletion else { return }
        didCallCompletion = true
        NotificationCenter.default.removeObserver(self, name: .walletsChanged, object: nil)
        completion?(result)
    }
    
}
