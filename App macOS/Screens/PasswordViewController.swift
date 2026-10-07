// ∅ 2026 lil org

import Cocoa

class PasswordViewController: NSViewController {
    var retainedReturnController: NSViewController?
    
    static func with(
        mode: Mode,
        reason: AuthenticationReason? = nil,
        reviewLifetime: NativeApprovalReviewLifetime? = nil,
        onboardingCancelled: (() -> Void)? = nil,
        credentialUnavailable: (() -> Void)? = nil,
        completion: ((Bool) -> Void)?
    ) -> PasswordViewController {
        let new = instantiate(PasswordViewController.self)
        new.mode = mode
        new.reason = reason
        new.reviewLifetime = reviewLifetime
        new.onboardingCancelled = onboardingCancelled
        new.credentialUnavailable = credentialUnavailable
        new.completion = completion
        return new
    }
    
    enum Mode {
        case create, repeatAfterCreate, enter
    }
    
    var keychain = Keychain.shared
    private var mode = Mode.create
    private var reason: AuthenticationReason?
    private var passwordToRepeat: String?
    private var completion: ((Bool) -> Void)?
    private var onboardingCancelled: (() -> Void)?
    private var credentialUnavailable: (() -> Void)?
    private var didCallCompletion = false
    private var initialRefreshTask: Task<Void, Never>?
    private var reviewLifetime: NativeApprovalReviewLifetime?
    private var isPasswordUnavailable = true
    private var isSaving = false
    private var saveTask: Task<Void, Never>?

    private var isCreatingPassword: Bool {
        switch mode {
        case .create, .repeatAfterCreate:
            return true
        case .enter:
            return false
        }
    }

    private var canSubmitPassword: Bool {
        mode == .enter ? !passwordTextField.stringValue.isEmpty : passwordTextField.stringValue.isOkAsPassword
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
        reviewLifetime?.register(self)
        guard reviewLifetime?.isActive != false else { return }
        
        passwordTextField.placeholderString = Strings.password
        cancelButton.title = Strings.cancel
        okButton.title = Strings.ok
        
        switchToMode(mode)
        passwordTextField.isEnabled = false
        
        if let reason = reason, reason != .start {
            reasonLabel.stringValue = "\(Strings.to) " + reason.title.lowercased()
        } else {
            reasonLabel.stringValue = ""
        }
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        initialRefreshTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.refreshPasswordState()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        initialRefreshTask?.cancel()
        saveTask?.cancel()
    }

    isolated deinit {
        initialRefreshTask?.cancel()
        saveTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.delegate = self
        refreshPasswordState()
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
        guard reviewLifetime?.isActive != false, !didCallCompletion, !isSaving else { return }
        let wasUnavailable = isPasswordUnavailable
        guard refreshPasswordState(), !wasUnavailable else { return }
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
                isSaving = true
                okButton.isEnabled = false
                cancelButton.isEnabled = false
                passwordTextField.isEnabled = false
                saveTask = Task { [weak self, keychain] in
                    let result: Result<Keychain.PasswordCreationResult, Error>
                    do { result = .success(try await keychain.createPasswordIfMissing(repeated)) }
                    catch { result = .failure(error) }
                    defer {
                        if case .success(.created) = result { WalletStoreSync.postLocalAndExternalChange() }
                    }
                    guard let self else { return }
                    isSaving = false
                    cancelButton.isEnabled = true
                    guard !Task.isCancelled, reviewLifetime?.isActive != false, !didCallCompletion else { return }
                    switch result {
                    case .success(.created):
                        callCompletion(result: true)
                    case .success(.alreadyExists):
                        passwordToRepeat = nil
                        passwordTextField.stringValue = ""
                        do {
                            guard try keychain.passwordState() == .present else {
                                showPasswordUnavailable()
                                return
                            }
                            leaveCreateFlowForExistingPassword()
                        } catch {
                            showPasswordUnavailable()
                        }
                    case .failure:
                        showPasswordUnavailable()
                    }
                }
            }
        case .enter:
            do {
                if try DeviceAuthentication.verify(password: passwordTextField.stringValue, keychain: keychain) {
                    callCompletion(result: true)
                }
            } catch {
                showPasswordUnavailable()
            }
        }
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        guard reviewLifetime?.isActive != false, !didCallCompletion, !isSaving else { return }
        switch mode {
        case .create:
            guard let credentialUnavailable else {
                callCompletion(result: false)
                return
            }
            let welcome = WelcomeViewController.new(
                onboardingCancelled: onboardingCancelled,
                credentialUnavailable: credentialUnavailable,
                completion: completion
            )
            welcome.keychain = keychain
            retireCredentialPresentation()
            view.window?.contentViewController = welcome
        case .repeatAfterCreate:
            switchToMode(.create)
        case .enter:
            callCompletion(result: false)
        }
    }
    
    private func callCompletion(result: Bool) {
        guard reviewLifetime?.isActive != false, !didCallCompletion else { return }
        let completion = completion
        let returningController = retainedReturnController
        retireCredentialPresentation()
        withExtendedLifetime(returningController) {
            completion?(result)
        }
    }

    private func cancelOnboarding() {
        guard !didCallCompletion else { return }
        guard let onboardingCancelled else {
            callCompletion(result: false)
            return
        }
        retireCredentialPresentation()
        onboardingCancelled()
    }

    func retireCredentialPresentation() {
        didCallCompletion = true
        initialRefreshTask?.cancel()
        initialRefreshTask = nil
        saveTask?.cancel()
        saveTask = nil
        passwordToRepeat = nil
        if isViewLoaded { passwordTextField.stringValue = "" }
        NotificationCenter.default.removeObserver(self)
        completion = nil
        onboardingCancelled = nil
        credentialUnavailable = nil
        retainedReturnController = nil
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
        guard !isSaving, !didCallCompletion, reviewLifetime?.isActive != false else { return false }
        do {
            switch try keychain.passwordState() {
            case .present:
                if isCreatingPassword {
                    leaveCreateFlowForExistingPassword()
                    return false
                }
            case .missing:
                guard isCreatingPassword else {
                    showPasswordUnavailable()
                    return false
                }
            }
            isPasswordUnavailable = false
            passwordTextField.isEnabled = true
            okButton.title = Strings.ok
            okButton.isEnabled = canSubmitPassword
            switch mode {
            case .create: titleLabel.stringValue = Strings.createPassword
            case .repeatAfterCreate: titleLabel.stringValue = Strings.repeatPassword
            case .enter: titleLabel.stringValue = Strings.enterPassword
            }
            return true
        } catch {
            showPasswordUnavailable()
            return false
        }
    }

    private func showPasswordUnavailable() {
        if let credentialUnavailable {
            retireCredentialPresentation()
            credentialUnavailable()
            return
        }
        isPasswordUnavailable = true
        passwordToRepeat = nil
        if mode == .repeatAfterCreate { mode = .create }
        passwordTextField.stringValue = ""
        passwordTextField.isEnabled = false
        titleLabel.stringValue = Strings.failedToLoad
        okButton.title = Strings.tryAgain
        okButton.isEnabled = true
    }

    private func leaveCreateFlowForExistingPassword() {
        callCompletion(result: false)
    }
    
}

extension PasswordViewController: NSTextFieldDelegate {
    
    func controlTextDidChange(_ obj: Notification) {
        okButton.isEnabled = !isSaving && (isPasswordUnavailable || canSubmitPassword)
    }
    
}

extension PasswordViewController: NSWindowDelegate {
    
    func windowWillClose(_ notification: Notification) {
        guard reviewLifetime == nil else { return }
        if isCreatingPassword { cancelOnboarding() }
        else { callCompletion(result: false) }
    }
    
}

extension PasswordViewController: NativeApprovalReviewTeardown {

    func invalidateNativeApprovalReview() {
        retainedReturnController = nil
        didCallCompletion = true
        NotificationCenter.default.removeObserver(self, name: .walletsChanged, object: nil)
        completion = nil
    }

}
