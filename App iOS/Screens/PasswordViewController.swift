// ∅ 2026 lil org

import UIKit

class PasswordViewController: UIViewController {
    
    enum Mode {
        case create, repeatAfterCreate, enter
    }
    
    var showAccountsListOnVision: (() -> Void)?
    
    private let keychain = Keychain.shared
    private var mode = Mode.create
    private var isSaving = false
    private var authenticationTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    var passwordToRepeat: String?
    
    @IBOutlet weak var passwordTextField: UITextField! {
        didSet {
            passwordTextField.delegate = self
            passwordTextField.placeholder = Strings.password
        }
    }
    
    @IBOutlet weak var initialOverlayView: UIView!
    @IBOutlet weak var okButton: UIButton!
    
    private var viewDidAppear = false

    private var adaptiveTitle: String {
        switch mode {
        case .create:
            return Strings.createPassword
        case .repeatAfterCreate:
            return Strings.repeatPassword
        case .enter:
            return Strings.enterPassword
        }
    }
    
    isolated deinit {
        saveTask?.cancel()
        authenticationTask?.cancel()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        saveTask?.cancel()
        authenticationTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        okButton.setTitle(Strings.ok, for: .normal)
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateAdaptiveTitleLayout()
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
                askForLocalAuthentication()
            }
        }
    }
    
    private func switchToMode(_ mode: Mode) {
        self.mode = mode
        updateAdaptiveTitleLayout()
    }

    private func updateAdaptiveTitleLayout() {
        if navigationController?.isNavigationBarHidden == true {
            removeFixedAdaptiveLargeTitleLayout()
        } else {
            updateAdaptiveLargeTitleLayout(adaptiveTitle)
        }
    }
    
    private func askForLocalAuthentication() {
        authenticationTask?.cancel()
        authenticationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let success = await LocalAuthentication.attempt(reason: Strings.enterWallet, presentPasswordAlertFrom: { nil }, passwordReason: nil)
            guard let self, !Task.isCancelled, viewIfLoaded?.window != nil else { return }
            if success {
                showAccountsList()
            } else {
                didFailLocalAuthentication()
            }
        }
    }
    
    private func didFailLocalAuthentication() {
        navigationController?.setNavigationBarHidden(false, animated: false)
        initialOverlayView.isHidden = true
        updateAdaptiveTitleLayout()
        focusOnPasswordTextField()
    }
    
    func focusOnPasswordTextField() {
        passwordTextField.becomeFirstResponder()
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        proceedIfPossible()
    }
    
    private func proceedIfPossible() {
        guard !isSaving else { return }
        switch mode {
        case .create:
            if passwordTextField.text?.isOkAsPassword == true {
                let passwordViewController = instantiate(PasswordViewController.self, from: .main)
                passwordViewController.passwordToRepeat = passwordTextField.text
                passwordViewController.showAccountsListOnVision = showAccountsListOnVision
                navigationController?.pushViewController(passwordViewController, animated: true)
            } else {
                showMessageAlert(text: Strings.typeAtLeast)
            }
        case .repeatAfterCreate:
            if let password = passwordTextField.text, !password.isEmpty, password == passwordToRepeat {
                isSaving = true
                okButton.isEnabled = false
                navigationController?.view.isUserInteractionEnabled = false
                saveTask = Task { [weak self, keychain] in
                    let saved = await keychain.save(password: password)
                    guard let self else { return }
                    isSaving = false
                    okButton.isEnabled = true
                    navigationController?.view.isUserInteractionEnabled = true
                    guard !Task.isCancelled else { return }
                    if saved {
                        showAccountsList()
                    } else {
                        showMessageAlert(text: Strings.somethingWentWrong)
                    }
                }
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
#if os(visionOS)
        showAccountsListOnVision?()
#else
        let accountsList = instantiate(AccountsListViewController.self, from: .main)
        UIApplication.shared.replaceRootViewController(with: accountsList.inNavigationController)
#endif
    }
    
}

extension PasswordViewController: UITextFieldDelegate {
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        proceedIfPossible()
        return true
    }
    
}
