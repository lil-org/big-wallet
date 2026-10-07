// ∅ 2026 lil org

import UIKit

class PasswordViewController: UIViewController, DataStateContainer {
    
    enum Mode {
        case create, repeatAfterCreate, enter, unavailable
    }
    
    var showAccountsListOnVision: (() -> Void)?
    
    var keychain = Keychain.shared
    private var mode = Mode.unavailable
    private var isSaving = false
    private var authenticationTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var shouldDiscardCreationStack = false
    private var isVisible = false
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
        case .unavailable:
            return Strings.failedToLoad
        }
    }
    
    isolated deinit {
        saveTask?.cancel()
        authenticationTask?.cancel()
        navigationTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        saveTask?.cancel()
        authenticationTask?.cancel()
        navigationTask?.cancel()
        isVisible = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        okButton.setTitle(Strings.ok, for: .normal)
        navigationItem.backButtonDisplayMode = .minimal
        
        configureDataState(.failedToLoad, actionHandler: { [weak self] in
            self?.refreshPasswordState()
        })
        if passwordToRepeat != nil { mode = .repeatAfterCreate }
        refreshPasswordState()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationBecameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationBecameActive), name: .walletsChanged, object: nil
        )
        
        if mode == .enter {
            initialOverlayView.isHidden = false
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
        if viewDidAppear { refreshPasswordState() }
        if mode == .create || mode == .repeatAfterCreate {
            focusOnPasswordTextField()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        discardCreationStackWhenVisible()
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

    @discardableResult
    private func refreshPasswordState() -> Bool {
        guard !isSaving else { return false }
        do {
            switch try keychain.passwordState() {
            case .present:
                if mode != .enter {
                    shouldDiscardCreationStack = mode == .create || mode == .repeatAfterCreate || shouldDiscardCreationStack
                    clearPasswordDrafts()
                    switchToMode(.enter)
                    discardCreationStackWhenVisible()
                }
            case .missing:
                shouldDiscardCreationStack = false
                if mode != .create && mode != .repeatAfterCreate {
                    clearPasswordDrafts()
                    switchToMode(.create)
                }
            }
            dataState = .hasData
            passwordTextField.isEnabled = true
            okButton.isEnabled = true
            initialOverlayView.isHidden = true
            return true
        } catch {
            showPasswordUnavailable()
            return false
        }
    }

    private func clearPasswordDrafts() {
        passwordToRepeat = nil
        passwordTextField.text = nil
    }

    private func discardCreationStackWhenVisible() {
        guard isVisible, shouldDiscardCreationStack else { return }
        navigationTask?.cancel()
        navigationTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, isVisible, mode == .enter,
                  shouldDiscardCreationStack, let navigationController,
                  navigationController.topViewController === self else { return }
            shouldDiscardCreationStack = false
            navigationController.setViewControllers([self], animated: false)
        }
    }

    private func showPasswordUnavailable() {
        shouldDiscardCreationStack = mode == .create || mode == .repeatAfterCreate || shouldDiscardCreationStack
        clearPasswordDrafts()
        switchToMode(.unavailable)
        passwordTextField.resignFirstResponder()
        passwordTextField.isEnabled = false
        okButton.isEnabled = false
        initialOverlayView.isHidden = true
        navigationController?.setNavigationBarHidden(false, animated: false)
        dataState = .failedToLoad
    }

    @objc private func applicationBecameActive() {
        guard viewIfLoaded?.window != nil, !isSaving else { return }
        refreshPasswordState()
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
                guard refreshPasswordState(), mode == .enter else { return }
                showAccountsList()
            } else {
                guard refreshPasswordState(), mode == .enter else { return }
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
        let previousMode = mode
        guard refreshPasswordState(), mode == previousMode else { return }
        switch mode {
        case .create:
            if passwordTextField.text?.isOkAsPassword == true {
                let passwordViewController = instantiate(PasswordViewController.self, from: .main)
                passwordViewController.passwordToRepeat = passwordTextField.text
                passwordViewController.keychain = keychain
                passwordViewController.showAccountsListOnVision = showAccountsListOnVision
                passwordTextField.text = nil
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
                    let result: Result<Keychain.PasswordCreationResult, Error>
                    do { result = .success(try await keychain.createPasswordIfMissing(password)) }
                    catch { result = .failure(error) }
                    defer {
                        if case .success(.created) = result { WalletStoreSync.postLocalAndExternalChange() }
                    }
                    guard let self else { return }
                    isSaving = false
                    okButton.isEnabled = true
                    navigationController?.view.isUserInteractionEnabled = true
                    guard !Task.isCancelled else { return }
                    switch result {
                    case .success(.created):
                        clearPasswordDrafts()
                        showAccountsList()
                    case .success(.alreadyExists):
                        clearPasswordDrafts()
                        shouldDiscardCreationStack = true
                        switchToMode(.unavailable)
                        if !refreshPasswordState() || mode != .enter { showPasswordUnavailable() }
                    case .failure:
                        showPasswordUnavailable()
                    }
                }
            } else {
                showMessageAlert(text: Strings.passwordDoesNotMatch)
            }
        case .enter:
            do {
                if try DeviceAuthentication.verify(password: passwordTextField.text ?? "", keychain: keychain) {
                    showAccountsList()
                } else {
                    showMessageAlert(text: Strings.passwordDoesNotMatch)
                }
            } catch {
                showPasswordUnavailable()
            }
        case .unavailable:
            break
        }
    }
    
    private func showAccountsList() {
        clearPasswordDrafts()
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
