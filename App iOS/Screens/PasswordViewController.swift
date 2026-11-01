import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import UIKit

class PasswordViewController: UIViewController, DataStateContainer, WalletAccessObserver {
    
    enum Mode {
        case create, repeatAfterCreate, enter, unavailable
    }
    
    var credentials = ApplicationServices.shared.credentials
    var access = ApplicationServices.shared.access
    private var mode = Mode.unavailable
    private var isSaving = false
    private var authenticationAttempt: WalletAccessController.AuthenticationAttempt?
    private var navigationTask: Task<Void, Never>?
    private var shouldDiscardCreationStack = false
    private var isVisible = false
    private var isRetired = false
    var passwordToRepeat: String?
    
    @IBOutlet weak var passwordTextField: UITextField! {
        didSet {
            passwordTextField.prepareSecretDraftHistory()
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
        authenticationAttempt?.cancel()
        navigationTask?.cancel()
        access.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        navigationTask?.cancel()
        navigationTask = nil
        isVisible = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        guard isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true else { return }
        if let transitionCoordinator,
           transitionCoordinator.animate(alongsideTransition: nil, completion: { [weak self] context in
               if !context.isCancelled { self?.retirePasswordForm() }
           }) { return }
        retirePasswordForm()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { retirePasswordForm() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        access.addObserver(self)
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
        guard !isSaving, !isRetired else { return false }
        do {
            switch try credentials.passwordState() {
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
        passwordTextField?.clearSecretDraft()
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
        guard viewIfLoaded?.window != nil, !isSaving, !isRetired else { return }
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
        guard !isRetired else { return }
        let attempt = beginAuthentication()
        attempt.replaceOperation { [weak self, credentials] operation in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard self?.canStartAuthentication(operation) == true else { return }
            let challenge = credentials.makeWalletAccessChallenge()
            guard operation.attachChallenge(challenge) else { return }
            let grant = await LocalAuthentication.authorize(reason: Strings.enterWallet,
                presentPasswordAlertFrom: { nil }, passwordReason: nil, challenge: challenge, credentials: credentials)
            guard let self, !Task.isCancelled, !isRetired, operation.isCurrent,
                  viewIfLoaded?.window != nil else {
                grant?.invalidate()
                return
            }
            if let grant {
                guard refreshPasswordState(), mode == .enter else { grant.invalidate(); return }
                finishAuthentication(grant, operation: operation)
            } else {
                cancelAuthentication(attempt)
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
        guard !isSaving, !isRetired else { return }
        let previousMode = mode
        guard refreshPasswordState(), mode == previousMode else { return }
        switch mode {
        case .create:
            if passwordTextField.text?.isOkAsPassword == true {
                let passwordViewController = instantiate(PasswordViewController.self, from: .main)
                passwordViewController.passwordToRepeat = passwordTextField.text
                passwordViewController.credentials = credentials
                passwordViewController.access = access
                clearPasswordDrafts()
                navigationController?.pushViewController(passwordViewController, animated: true)
            } else {
                showMessageAlert(text: Strings.typeAtLeast)
            }
        case .repeatAfterCreate:
            if let password = passwordTextField.text, !password.isEmpty, password == passwordToRepeat {
                clearPasswordDrafts()
                let attempt = beginAuthentication()
                guard attempt.isCurrent else { return }
                isSaving = true
                okButton.isEnabled = false
                navigationController?.view.isUserInteractionEnabled = false
                attempt.replaceOperation { [weak self, credentials] operation in
                    let result: Result<WalletPasswordCreationResult, Error>
                    do { result = .success(try await credentials.createPasswordIfMissing(password)) }
                    catch { result = .failure(error) }
                    guard let self, !Task.isCancelled, !isRetired, operation.isCurrent else { return }
                    isSaving = false
                    okButton.isEnabled = true
                    navigationController?.view.isUserInteractionEnabled = true
                    switch result {
                    case .success(.created):
                        let challenge = credentials.makeWalletAccessChallenge()
                        guard operation.attachChallenge(challenge) else { return }
                        if let grant = try? credentials.verify(password: password, challenge: challenge) {
                            finishAuthentication(grant, operation: operation)
                        } else {
                            cancelAuthentication(attempt)
                            showPasswordUnavailable()
                        }
                    case .success(.alreadyExists):
                        cancelAuthentication(attempt)
                        clearPasswordDrafts()
                        shouldDiscardCreationStack = true
                        switchToMode(.unavailable)
                        if !refreshPasswordState() || mode != .enter { showPasswordUnavailable() }
                    case .failure:
                        cancelAuthentication(attempt)
                        showPasswordUnavailable()
                    }
                }
            } else {
                showMessageAlert(text: Strings.passwordDoesNotMatch)
            }
        case .enter:
            let password = passwordTextField.text ?? ""
            let attempt = beginAuthentication()
            guard attempt.isCurrent else { return }
            let challenge = credentials.makeWalletAccessChallenge()
            defer { challenge.invalidate() }
            let operation = attempt.replaceOperation(challenge: challenge)
            do {
                if let authorization = try credentials.verify(password: password, challenge: challenge) {
                    finishAuthentication(authorization, operation: operation)
                } else {
                    cancelAuthentication(attempt)
                    showMessageAlert(text: Strings.passwordDoesNotMatch)
                }
            } catch {
                cancelAuthentication(attempt)
                showPasswordUnavailable()
            }
        case .unavailable:
            break
        }
    }
    
    private func beginAuthentication() -> WalletAccessController.AuthenticationAttempt {
        cancelAuthentication()
        let attempt = access.beginAuthentication { [weak self] cancelled in
            guard let self, authenticationAttempt === cancelled else { return }
            authenticationAttempt = nil
            authenticationWasCancelled()
        }
        if !isRetired, attempt.isCurrent { authenticationAttempt = attempt }
        else { attempt.cancel() }
        return attempt
    }

    private func canStartAuthentication(_ operation: WalletAccessController.AuthenticationAttempt.Operation) -> Bool {
        !isRetired && operation.isCurrent && isVisible && viewIfLoaded?.window != nil
    }

    private func finishAuthentication(_ grant: WalletAuthenticationGrant, operation: WalletAccessController.AuthenticationAttempt.Operation) {
        guard !isRetired, operation.isCurrent, let attempt = authenticationAttempt else { grant.invalidate(); return }
        clearPasswordDrafts()
        if operation.complete(grant) {
            if authenticationAttempt === attempt { authenticationAttempt = nil }
        } else {
            cancelAuthentication(attempt)
            if !isRetired, refreshPasswordState() { didFailLocalAuthentication() }
        }
    }

    private func authenticationWasCancelled() {
        clearPasswordDrafts()
        guard isViewLoaded, !isRetired else { return }
        isSaving = false
        if mode == .repeatAfterCreate { switchToMode(.create) }
        passwordTextField.isEnabled = mode != .unavailable
        okButton.isEnabled = mode != .unavailable
        navigationController?.view.isUserInteractionEnabled = true
        navigationController?.setNavigationBarHidden(false, animated: false)
        initialOverlayView.isHidden = true
        updateAdaptiveTitleLayout()
    }

    private func cancelAuthentication() {
        guard let attempt = authenticationAttempt else { return }
        cancelAuthentication(attempt)
    }

    private func cancelAuthentication(_ attempt: WalletAccessController.AuthenticationAttempt) {
        attempt.cancel()
        if authenticationAttempt === attempt { authenticationAttempt = nil }
    }

    func walletAccessDidLock() {
        retirePasswordForm()
    }

    private func retirePasswordForm() {
        guard !isRetired else { return }
        isRetired = true
        cancelAuthentication()
        navigationTask?.cancel()
        navigationTask = nil
        clearPasswordDrafts()
        clearPresentedWalletInputs()
        dismissPresentedWalletContent()
        viewIfLoaded?.endEditing(true)
        viewIfLoaded?.isUserInteractionEnabled = false
    }

    func walletAccessDidUnlock() {
        retirePasswordForm()
    }
    
}

extension PasswordViewController: UITextFieldDelegate {
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        proceedIfPossible()
        return true
    }
    
}
