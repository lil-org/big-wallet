// ∅ 2026 lil org

import Cocoa

class ImportViewController: NSViewController {
    
    private let walletsManager = WalletsManager.shared
    private var validationTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var inputValidationResult = WalletsManager.InputValidationResult.invalid
    private var isImporting = false
    
    @IBOutlet weak var titleTextField: NSTextField!
    @IBOutlet weak var textField: NSTextField! {
        didSet {
            textField.delegate = self
            textField.placeholderString = Strings.importWalletTextFieldPlaceholder
        }
    }
    
    @IBOutlet weak var cancelButton: NSButton!
    @IBOutlet weak var okButton: NSButton!
    
    isolated deinit {
        validationTask?.cancel()
        importTask?.cancel()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        validationTask?.cancel()
        importTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        cancelButton.title = Strings.cancel
        okButton.title = Strings.ok
        titleTextField.stringValue = Strings.importWallet.replacingOccurrences(of: " ", with: "\n")
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        guard !isImporting else { return }
        if inputValidationResult == .requiresPassword {
            showPasswordAlert()
        } else {
            importWith(input: textField.stringValue, password: nil)
        }
    }
 
    private func showPasswordAlert() {
        let alert = Alert()
        let input = textField.stringValue
        alert.messageText = Strings.enterKeystorePassword
        alert.alertStyle = .informational
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.cancel)
        
        let passwordTextField = NSSecureTextField(
            frame: NSRect(x: 0, y: 0, width: 160, height: 20)
        )
        passwordTextField.bezelStyle = .roundedBezel
        alert.accessoryView = passwordTextField
        passwordTextField.isAutomaticTextCompletionEnabled = false
        passwordTextField.alignment = .center
        
        alert.window.initialFirstResponder = passwordTextField
        if alert.runModal() == .alertFirstButtonReturn {
            importWith(
                input: input,
                password: passwordTextField.stringValue
            )
        }
    }

    private func importWith(input: String, password: String?) {
        guard !isImporting else { return }
        isImporting = true
        okButton.isEnabled = false
        cancelButton.isEnabled = false
        importTask = Task { [weak self, walletsManager] in
            do {
                let wallet = try await walletsManager.addWallet(input: input, inputPassword: password)
                guard let self else { return }
                finishImporting()
                guard !Task.isCancelled else { return }
                showAccountsList(newWalletId: wallet.id)
            } catch {
                guard let self else { return }
                finishImporting()
                guard !Task.isCancelled else { return }
                presentMessageAlert(Strings.failedToImportWallet, style: .critical)
            }
        }
    }

    private func finishImporting() {
        isImporting = false
        okButton.isEnabled = inputValidationResult != .invalid
        cancelButton.isEnabled = true
    }
    

    private func showAccountsList(newWalletId: String?) {
        let accountsListViewController = instantiate(AccountsListViewController.self)
        accountsListViewController.newWalletId = newWalletId
        view.window?.contentViewController = accountsListViewController
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        showAccountsList(newWalletId: nil)
    }
    
}

extension ImportViewController: NSTextFieldDelegate {
    
    func controlTextDidChange(_ obj: Notification) {
        validationTask?.cancel()
        let input = textField.stringValue
        okButton.isEnabled = false
        validationTask = Task { [weak self, walletsManager] in
            let result = await walletsManager.validateWalletInput(input)
            guard let self, !Task.isCancelled, textField.stringValue == input else { return }
            inputValidationResult = result
            okButton.isEnabled = !isImporting && result != .invalid
        }
    }
    
}
