// ∅ 2025 lil org

import UIKit

class PasswordViewController: UIViewController {
    
    enum Mode {
        case create, repeatAfterCreate, enter
    }
    
    private let keychain = Keychain.shared
    private var mode = Mode.create
    var passwordToRepeat: String?
    
    @IBOutlet weak var passwordTextField: UITextField! {
        didSet {
            passwordTextField.delegate = self
            passwordTextField.addTarget(self, action: #selector(textFieldChanged), for: .editingChanged)
            passwordTextField.placeholder = Strings.password
        }
    }
    
    @IBOutlet weak var initialOverlayView: UIView!
    @IBOutlet weak var okButton: UIButton!
    
    private var viewDidAppear = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        okButton.setTitle(Strings.ok, for: .normal)
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.backButtonDisplayMode = .minimal
        
        if passwordToRepeat != nil {
            switchToMode(.repeatAfterCreate)
        } else if keychain.password != nil {
            switchToMode(.enter)
        } else {
            switchToMode(.create)
        }
        
        if mode == .enter {
#if os(iOS)
            navigationController?.setNavigationBarHidden(true, animated: false)
#endif
        } else {
            initialOverlayView.isHidden = true
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if mode != .enter {
            focusOnPasswordTextField()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !viewDidAppear {
            viewDidAppear = true
            if mode == .enter {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                    self?.askForLocalAuthentication()
                }
            }
        }
    }
    
    private func switchToMode(_ mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            navigationItem.title = Strings.createPassword
        case .repeatAfterCreate:
            navigationItem.title = Strings.repeatPassword
        case .enter:
            navigationItem.title = Strings.enterPassword
        }
    }
    
    private func askForLocalAuthentication() {
        LocalAuthentication.attempt(reason: Strings.enterWallet, presentPasswordAlertFrom: nil, passwordReason: nil) { [weak self] success in
            if success {
                self?.showAccountsList()
            } else {
                self?.didFailLocalAuthentication()
            }
        }
    }
    
    private func didFailLocalAuthentication() {
        navigationController?.setNavigationBarHidden(false, animated: false)
        initialOverlayView.isHidden = true
        focusOnPasswordTextField()
    }
    
    func focusOnPasswordTextField() {
        passwordTextField.becomeFirstResponder()
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        proceedIfPossible()
    }
    
    @objc private func textFieldChanged() {}
    
    private func proceedIfPossible() {
        switch mode {
        case .create:
            if passwordTextField.text?.isOkAsPassword == true {
                let passwordViewController = instantiate(PasswordViewController.self, from: .main)
                passwordViewController.passwordToRepeat = passwordTextField.text
                navigationController?.pushViewController(passwordViewController, animated: true)
            } else {
                showMessageAlert(text: Strings.pleaseTypeAtLeast)
            }
        case .repeatAfterCreate:
            if let password = passwordTextField.text, !password.isEmpty, password == passwordToRepeat {
                keychain.save(password: password)
                showAccountsList()
            } else {
                showMessageAlert(text: Strings.passwordDoesNotMatch)
            }
        case .enter:
            if passwordTextField.text == keychain.password {
                showAccountsList()
            } else {
                showMessageAlert(text: Strings.passwordDoesNotMatch)
            }
        }
    }
    
    private func showAccountsList() {
        let accountsList = instantiate(AccountsListViewController.self, from: .main)
#if os(visionOS)
        view.window?.rootViewController = accountsList.inNavigationController
#else
        UIApplication.shared.replaceRootViewController(with: accountsList.inNavigationController)
#endif
    }
    
}

extension PasswordViewController: UITextFieldDelegate {
    
    func textFieldDidBeginEditing(_ textField: UITextField) {
        textFieldChanged()
    }
    
    func textFieldDidEndEditing(_ textField: UITextField, reason: UITextField.DidEndEditingReason) {
        textFieldChanged()
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        proceedIfPossible()
        return true
    }
    
}
