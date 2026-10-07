// ∅ 2026 lil org

import Cocoa

class WelcomeViewController: NSViewController {
    var keychain = Keychain.shared
    
    static func new(
        onboardingCancelled: (() -> Void)? = nil,
        completion: ((Bool) -> Void)?
    ) -> WelcomeViewController {
        let new = instantiate(WelcomeViewController.self)
        new.onboardingCancelled = onboardingCancelled
        new.completion = completion
        return new
    }
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var messageLabel: NSTextField!
    @IBOutlet weak var getStartedButton: NSButton!
    
    private var completion: ((Bool) -> Void)?
    private var onboardingCancelled: (() -> Void)?
    private var didCallCompletion = false
    private var initialRefreshTask: Task<Void, Never>?
    private var isPasswordUnavailable = true
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        titleLabel.stringValue = Strings.bigWallet
        messageLabel.stringValue = Strings.welcomeScreenText
        getStartedButton.title = Strings.getStarted
        getStartedButton.isEnabled = false
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        initialRefreshTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.walletsChanged()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        initialRefreshTask?.cancel()
    }

    isolated deinit {
        initialRefreshTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        let wasUnavailable = isPasswordUnavailable
        guard refreshPasswordState(), !wasUnavailable else { return }
        didCallCompletion = true
        NotificationCenter.default.removeObserver(self)
        let passwordViewController = PasswordViewController.with(
            mode: .create,
            onboardingCancelled: onboardingCancelled,
            completion: completion
        )
        passwordViewController.keychain = keychain
        view.window?.contentViewController = passwordViewController
    }

    @objc private func walletsChanged() {
        refreshPasswordState()
    }

    @objc private func applicationBecameActive() {
        guard viewIfLoaded?.window != nil else { return }
        refreshPasswordState()
    }

    @discardableResult
    private func refreshPasswordState() -> Bool {
        guard !didCallCompletion else { return false }
        do {
            guard try keychain.passwordState() == .missing else {
                callCompletion(result: false)
                return false
            }
            isPasswordUnavailable = false
            messageLabel.stringValue = Strings.welcomeScreenText
            getStartedButton.title = Strings.getStarted
            getStartedButton.isEnabled = true
            return true
        } catch {
            isPasswordUnavailable = true
            messageLabel.stringValue = Strings.failedToLoad
            getStartedButton.title = Strings.tryAgain
            getStartedButton.isEnabled = true
            return false
        }
    }

    private func callCompletion(result: Bool) {
        guard !didCallCompletion else { return }
        didCallCompletion = true
        NotificationCenter.default.removeObserver(self, name: .walletsChanged, object: nil)
        completion?(result)
    }
    
}
