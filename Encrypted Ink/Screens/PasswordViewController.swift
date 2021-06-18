// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class PasswordViewController: NSViewController {
    
    static func with(mode: Mode, completion: ((Bool) -> Void)?) -> PasswordViewController {
        let new = instantiate(PasswordViewController.self)
        new.mode = mode
        new.completion = completion
        return new
    }
    
    enum Mode {
        case create, repeatAfterCreate, enter
    }
    
    private var mode = Mode.create
    private var passwordToRepeat: String?
    private var completion: ((Bool) -> Void)?
    
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
        switchToMode(mode)
    }

    func switchToMode(_ mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            titleLabel.stringValue = "Create Password"
            passwordToRepeat = nil
        case .repeatAfterCreate:
            titleLabel.stringValue = "Repeat Password"
            passwordToRepeat = passwordTextField.stringValue
        case .enter:
            titleLabel.stringValue = "Enter Password"
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
                Keychain.save(password: repeated)
                completion?(true)
            }
        case .enter:
            print("yo") // TODO: implement
        }
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        switch mode {
        case .create:
            view.window?.contentViewController = WelcomeViewController.new(completion: completion)
        case .repeatAfterCreate:
            switchToMode(.create)
        case .enter:
            Window.closeAll() // TODO: implement
        }
    }
    
}

extension PasswordViewController: NSTextFieldDelegate {
    
    func controlTextDidChange(_ obj: Notification) {
        okButton.isEnabled = passwordTextField.stringValue.count >= 4
    }
    
}
