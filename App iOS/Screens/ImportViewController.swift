import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import UIKit

final class SecretImportTextView: UITextView {
    private struct ObservedManager {
        weak var value: UndoManager?
    }

    private var editingUndoManagers = [ObservedManager]()

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder { captureUndoManager() }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        captureUndoManager()
        return super.resignFirstResponder()
    }

    private func captureUndoManager() {
        editingUndoManagers.removeAll { $0.value == nil }
        guard let manager = undoManager, !editingUndoManagers.contains(where: { $0.value === manager }) else { return }
        editingUndoManagers.append(ObservedManager(value: manager))
    }

    func clearSecretDraft() {
        captureUndoManager()
        let retainedManagers = editingUndoManagers.compactMap(\.value)
        retainedManagers.forEach { $0.removeAllActions() }
        text = nil
        captureUndoManager()
        retainedManagers.forEach { $0.removeAllActions() }
        editingUndoManagers.compactMap(\.value).forEach { $0.removeAllActions() }
        editingUndoManagers.removeAll()
    }
}

class ImportViewController: WalletAccessViewController {
    var completion: ((Bool) -> Void)?
    var validateWalletInput: @MainActor (String) async -> WalletsManager.InputValidationResult = {
        await ApplicationServices.shared.wallets.validateWalletInput($0)
    }
    var importWallet: @MainActor (String, String?, WalletAccessSession) async throws -> WalletSnapshot = {
        try await ApplicationServices.shared.wallets.addWallet(input: $0, inputPassword: $1, access: $2)
    }
    var makePasswordPrompt: @MainActor () -> LocalAuthentication.AlertRequest = { .init() }

    private var layoutTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var passwordPrompt: LocalAuthentication.AlertRequest?
    private var validationGeneration: UInt64 = 0
    private var submissionGeneration: UInt64 = 0
    private var isWaiting = false
    private(set) var isRetired = false
    private var inputValidationResult = WalletsManager.InputValidationResult.invalid

    @IBOutlet weak var placeholderLabel: UILabel! {
        didSet { placeholderLabel.text = Strings.importWalletTextFieldPlaceholder }
    }
    @IBOutlet weak var pasteButton: UIButton!
    @IBOutlet weak var okButton: UIButton!
    @IBOutlet weak var textView: UITextView! {
        didSet {
            textView.delegate = self
            textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
            textView.layer.cornerRadius = 5
            textView.layer.borderWidth = CGFloat.pixel(displayScale: textView.traitCollection.displayScale)
            textView.layer.borderColor = UIColor.separator.cgColor
        }
    }

    isolated deinit {
        layoutTask?.cancel()
        validationTask?.cancel()
        importTask?.cancel()
        passwordPrompt?.cancel()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true else { return }
        if let transitionCoordinator,
           transitionCoordinator.animate(alongsideTransition: nil, completion: { [weak self] context in
               if !context.isCancelled { self?.retireImport() }
           }) { return }
        retireImport()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        layoutTask?.cancel()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { retireImport() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        okButton.setTitle(Strings.ok, for: .normal)
        pasteButton.setTitle(Strings.paste, for: .normal)
        configureAdaptiveLargeTitle(Strings.importWallet)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: Strings.cancel, style: .plain, target: self, action: #selector(cancelImport))
        okButton.configurationUpdateHandler = { [weak self] button in
            let isWaiting = self?.isWaiting == true
            button.configuration?.title = isWaiting ? "" : Strings.ok
            button.configuration?.showsActivityIndicator = isWaiting
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateAdaptiveLargeTitleLayout(Strings.importWallet)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !isRetired, hasWalletAccess else { return }
        layoutTask?.cancel()
        layoutTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, !isRetired, hasWalletAccess else { return }
            navigationController?.navigationBar.sizeToFit()
            textView.becomeFirstResponder()
        }
    }

    @IBAction func pasteButtonTapped(_ sender: Any) {
        guard !isRetired, beginWalletAction() else { return }
        if let text = UIPasteboard.general.string {
            textView.text = text
            validateInput(proceedIfValid: false)
        }
    }

    @IBAction func okButtonTapped(_ sender: Any) {
        guard !isRetired, beginWalletAction() else { return }
        attemptImportWithCurrentInput()
    }

    private func attemptImportWithCurrentInput() {
        guard !isRetired, hasWalletAccess, !isWaiting, importTask == nil else { return }
        validationGeneration &+= 1
        validationTask?.cancel()
        validationTask = nil
        submissionGeneration &+= 1
        let generation = submissionGeneration
        let input = textView.text ?? ""
        let needsPassword = inputValidationResult == .requiresPassword
        let makePrompt = makePasswordPrompt
        let importWallet = importWallet
        importTask = Task { [weak self] in
            guard self?.acceptsSubmission(generation) == true else { return }
            let password: String?
            if needsPassword {
                let prompt = makePrompt()
                self?.passwordPrompt = prompt
                password = await prompt.present(from: { [weak self] in
                    guard let self, acceptsSubmission(generation) else { return nil }
                    return self
                }, title: Strings.enterKeystorePassword, message: nil, requestsPassword: true,
                    authorizeConfirmation: { [weak self] in
                        guard let self, acceptsSubmission(generation) else { return false }
                        return beginWalletAction()
                    })
                guard self?.acceptsSubmission(generation) == true else { return }
                self?.passwordPrompt = nil
                guard password != nil else {
                    self?.importTask = nil
                    return
                }
            } else {
                password = nil
            }
            self?.setWaiting(true)
            let result: Result<WalletSnapshot, Error>
            do {
                guard let self else { return }
                let session = try requireCurrentAccess()
                result = .success(try await importWallet(input, password, session))
            }
            catch { result = .failure(error) }
            guard let self, acceptsSubmission(generation) else { return }
            self.importTask = nil
            switch result {
            case .success:
                let completion = completion
                retireImport()
                dismiss(animated: true)
                completion?(true)
            case .failure(let error):
                setWaiting(false)
                showMessageAlert(text: error as? WalletImportError == .limitExceeded
                    ? Strings.walletImportLimitExceeded : Strings.failedToImportWallet)
            }
        }
    }

    private func acceptsSubmission(_ generation: UInt64) -> Bool {
        !Task.isCancelled && !isRetired && submissionGeneration == generation && hasWalletAccess
    }

    @objc func cancelImport() {
        guard !isRetired, beginWalletAction() else { return }
        retireImport()
        dismiss(animated: true)
    }

    private func retireImport() {
        guard !isRetired else { return }
        isRetired = true
        submissionGeneration &+= 1
        validationGeneration &+= 1
        layoutTask?.cancel()
        layoutTask = nil
        validationTask?.cancel()
        validationTask = nil
        importTask?.cancel()
        importTask = nil
        passwordPrompt?.cancel()
        passwordPrompt = nil
        if let textView = textView as? SecretImportTextView { textView.clearSecretDraft() }
        else { textView?.text = nil }
        clearPresentedWalletInputs()
        viewIfLoaded?.endEditing(true)
        viewIfLoaded?.isUserInteractionEnabled = false
        inputValidationResult = .invalid
        completion = nil
        okButton?.isEnabled = false
        pasteButton?.isEnabled = false
        navigationItem.leftBarButtonItem?.isEnabled = false
    }

    private func setWaiting(_ waiting: Bool) {
        guard !isRetired, waiting != isWaiting else { return }
        isWaiting = waiting
        view.isUserInteractionEnabled = !waiting
        isModalInPresentation = waiting
        navigationItem.leftBarButtonItem?.isEnabled = !waiting
        okButton.setNeedsUpdateConfiguration()
    }

    private func validateInput(proceedIfValid: Bool) {
        guard !isRetired, hasWalletAccess else { return }
        placeholderLabel.isHidden = !textView.text.isEmpty
        validationGeneration &+= 1
        let generation = validationGeneration
        validationTask?.cancel()
        let input = textView.text ?? ""
        let validate = validateWalletInput
        okButton.isEnabled = false
        validationTask = Task { [weak self] in
            let result = await validate(input)
            guard let self, !Task.isCancelled, !isRetired, validationGeneration == generation,
                  hasWalletAccess, textView.text == input else { return }
            validationTask = nil
            inputValidationResult = result
            let isValid = result != .invalid
            okButton.isEnabled = isValid && !isWaiting
            if isValid && proceedIfValid { attemptImportWithCurrentInput() }
        }
    }

    override func walletAccessDidLock() {
        retireImport()
        super.walletAccessDidLock()
    }
}

extension ImportViewController: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !isRetired, beginWalletAction() else { return false }
        if text == "\n" {
            validateInput(proceedIfValid: true)
            return false
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isRetired, beginWalletAction() else { return }
        validateInput(proceedIfValid: false)
    }
}
