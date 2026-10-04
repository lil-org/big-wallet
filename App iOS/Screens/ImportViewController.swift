// ∅ 2026 lil org

import UIKit

class ImportViewController: UIViewController {
    
    var completion: ((Bool) -> Void)?
    private let walletsManager = WalletsManager.shared
    private var layoutTask: Task<Void, Never>?
    
    @IBOutlet weak var placeholderLabel: UILabel! {
        didSet {
            placeholderLabel.text = Strings.importWalletTextFieldPlaceholder
        }
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
    
    private var isWaiting = false
    private var validationTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var deferredImportTask: Task<Void, Never>?
    private var inputValidationResult = WalletsManager.InputValidationResult.invalid
    
    isolated deinit {
        deferredImportTask?.cancel()
        layoutTask?.cancel()
        validationTask?.cancel()
        importTask?.cancel()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        layoutTask?.cancel()
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            validationTask?.cancel()
            importTask?.cancel()
            deferredImportTask?.cancel()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        okButton.setTitle(Strings.ok, for: .normal)
        pasteButton.setTitle(Strings.paste, for: .normal)
        
        configureAdaptiveLargeTitle(Strings.importWallet)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: Strings.cancel, style: .plain, target: self, action: #selector(dismissAnimated))
        
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
        layoutTask?.cancel()
        layoutTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.navigationController?.navigationBar.sizeToFit()
            self?.textView.becomeFirstResponder()
        }
    }
    
    @IBAction func pasteButtonTapped(_ sender: Any) {
        if let text = UIPasteboard.general.string {
            textView.text = text
            validateInput(proceedIfValid: false)
        }
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        attemptImportWithCurrentInput()
    }
    
    private func attemptImportWithCurrentInput() {
        guard !isWaiting else { return }
        if inputValidationResult == .requiresPassword {
            askPassword()
        } else {
            importWith(input: textView.text, password: nil)
        }
    }
    
    private func askPassword() {
        showPasswordAlert(title: Strings.enterKeystorePassword, message: nil) { [weak self] password in
            guard let self, let password else { return }
            let input = textView.text ?? ""
            setWaiting(true)
            deferredImportTask?.cancel()
            deferredImportTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.importWith(input: input, password: password)
            }
        }
    }
    
    private func importWith(input: String, password: String?) {
        setWaiting(true)
        importTask = Task { [weak self, walletsManager] in
            do {
                _ = try await walletsManager.addWallet(input: input, inputPassword: password)
                guard let self else { return }
                setWaiting(false)
                guard !Task.isCancelled else { return }
                completion?(true)
                dismissAnimated()
            } catch {
                guard let self else { return }
                setWaiting(false)
                guard !Task.isCancelled else { return }
                showMessageAlert(text: Strings.failedToImportWallet)
            }
        }
    }
    
    private func setWaiting(_ waiting: Bool) {
        guard waiting != self.isWaiting else { return }
        self.isWaiting = waiting
        view.isUserInteractionEnabled = !waiting
        isModalInPresentation = waiting
        navigationItem.leftBarButtonItem?.isEnabled = !waiting
        okButton.setNeedsUpdateConfiguration()
    }
    
    private func validateInput(proceedIfValid: Bool) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        validationTask?.cancel()
        let input = textView.text ?? ""
        okButton.isEnabled = false
        validationTask = Task { [weak self, walletsManager] in
            let result = await walletsManager.validateWalletInput(input)
            guard let self, !Task.isCancelled, textView.text == input else { return }
            inputValidationResult = result
            let isValid = result != .invalid
            okButton.isEnabled = isValid && !isWaiting
            if isValid && proceedIfValid { attemptImportWithCurrentInput() }
        }
    }
    
}

extension ImportViewController: UITextViewDelegate {
    
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" {
            validateInput(proceedIfValid: true)
            return false
        } else {
            return true
        }
    }
    
    func textViewDidChange(_ textView: UITextView) {
        validateInput(proceedIfValid: false)
    }
    
}
