// ∅ 2026 lil org

import Cocoa

class PasswordViewController: NSViewController {
    
    static func with(mode: Mode, reason: AuthenticationReason? = nil, completion: ((Bool) -> Void)?) -> PasswordViewController {
        let new = instantiate(PasswordViewController.self)
        new.mode = mode
        new.reason = reason
        new.completion = completion
        return new
    }
    
    enum Mode {
        case create, repeatAfterCreate, enter
    }
    
    private let keychain = Keychain.shared
    private var mode = Mode.create
    private var reason: AuthenticationReason?
    private var passwordToRepeat: String?
    private var completion: ((Bool) -> Void)?
    private var didCallCompletion = false

    private var isCreatingPassword: Bool {
        switch mode {
        case .create, .repeatAfterCreate:
            return true
        case .enter:
            return false
        }
    }
    
    @IBOutlet weak var reasonLabel: NSTextField!
    @IBOutlet weak var cancelButton: NSButton!
    @IBOutlet weak var okButton: NSButton!
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var passwordTextField: NSSecureTextField! {
        didSet {
            passwordTextField.delegate = self
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        passwordTextField.placeholderString = Strings.password
        cancelButton.title = Strings.cancel
        okButton.title = Strings.ok
        
        switchToMode(mode)
        
        if let reason = reason, reason != .start {
            reasonLabel.stringValue = "\(Strings.to) " + reason.title.lowercased()
        } else {
            reasonLabel.stringValue = ""
        }
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil)
        DispatchQueue.main.async { [weak self] in
            self?.walletsChanged()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.delegate = self
    }
    
    func switchToMode(_ mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            titleLabel.stringValue = Strings.createPassword
            passwordToRepeat = nil
        case .repeatAfterCreate:
            titleLabel.stringValue = Strings.repeatPassword
            passwordToRepeat = passwordTextField.stringValue
        case .enter:
            titleLabel.stringValue = Strings.enterPassword
        }
        passwordTextField.stringValue = ""
        okButton.isEnabled = false
    }
    
    @IBAction func actionButtonTapped(_ sender: Any) {
        switch mode {
        case .create:
            switchToMode(.repeatAfterCreate)
        case .repeatAfterCreate:
            let repeated = passwordTextField.stringValue
            if repeated == passwordToRepeat {
                guard CurrentApp.canCreatePassword else {
                    callCompletion(result: false)
                    return
                }
                guard keychain.password == nil else {
                    leaveCreateFlowForExistingPassword()
                    return
                }
                guard keychain.createPasswordIfMissing(repeated) else {
                    if keychain.password != nil {
                        leaveCreateFlowForExistingPassword()
                    } else {
                        Alert.showWithMessage(Strings.somethingWentWrong, style: .informational)
                    }
                    return
                }
                callCompletion(result: true)
                WalletStoreSync.postLocalAndExternalChange()
            }
        case .enter:
            if keychain.password == passwordTextField.stringValue {
                callCompletion(result: true)
            }
        }
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        switch mode {
        case .create:
            view.window?.contentViewController = WelcomeViewController.new(completion: completion)
        case .repeatAfterCreate:
            switchToMode(.create)
        case .enter:
            callCompletion(result: false)
        }
    }
    
    private func callCompletion(result: Bool) {
        if !didCallCompletion {
            didCallCompletion = true
            NotificationCenter.default.removeObserver(self, name: .walletsChanged, object: nil)
            completion?(result)
        }
    }

    @objc private func walletsChanged() {
        guard isCreatingPassword, keychain.password != nil else { return }
        leaveCreateFlowForExistingPassword()
    }

    private func leaveCreateFlowForExistingPassword() {
        callCompletion(result: false)
    }
    
}

extension PasswordViewController: NSTextFieldDelegate {
    
    func controlTextDidChange(_ obj: Notification) {
        okButton.isEnabled = passwordTextField.stringValue.isOkAsPassword
    }
    
}

extension PasswordViewController: NSWindowDelegate {
    
    func windowWillClose(_ notification: Notification) {
        callCompletion(result: false)
    }
    
}
