import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Cocoa

class ImportViewController: NSViewController, NativeWalletProtectedContent {
    struct Dependencies {
        var validate: @MainActor (String) async -> WalletsManager.InputValidationResult = {
            await ApplicationServices.shared.wallets.validateWalletInput($0)
        }
        var prepareStore: @MainActor () async -> Bool = {
            let wallets = ApplicationServices.shared.wallets
            if wallets.isStoreReady { return true }
            return await wallets.reloadFromStore()
        }
        var importWallet: @MainActor (String, String?, WalletAccessSession) async throws -> WalletSnapshot = {
            try await ApplicationServices.shared.wallets.addWallet(input: $0, inputPassword: $1, access: $2)
        }
        var runPasswordPrompt: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    }

    let walletAccess: NativeWalletAccess

    init?(coder: NSCoder, access: NativeWalletAccess) {
        walletAccess = access
        super.init(coder: coder)
    }

    required init?(coder: NSCoder) { return nil }

    static func with(access: NativeWalletAccess) -> ImportViewController {
        instantiate(ImportViewController.self) { ImportViewController(coder: $0, access: access) }
    }
    var dependencies = Dependencies()
    private var validationTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var inputValidationResult = WalletsManager.InputValidationResult.invalid
    private var isImporting = false
    private var isRetired = false
    private var passwordPrompt: NSAlert?
    private var hasCurrentPresentation: Bool {
        !isRetired && walletAccess.hasCurrentPresentation && viewIfLoaded?.window?.contentViewController === self
    }

    private func validateManagementActions() -> Bool { walletAccess.validateCurrentAccess() && hasCurrentPresentation }

    func retire() {
        retireImport()
    }

    private func retireImport() {
        guard !isRetired else { return }
        isRetired = true
        validationTask?.cancel()
        validationTask = nil
        importTask?.cancel()
        importTask = nil
        inputValidationResult = .invalid
        Window.clearSecretInput(passwordPrompt?.accessoryView as? NSTextField)
        if let passwordPrompt, NSApp.modalWindow === passwordPrompt.window { NSApp.abortModal() }
        passwordPrompt?.window.orderOut(nil)
        passwordPrompt = nil
        if isViewLoaded {
            Window.clearSecretInput(textField)
            textField.isEnabled = false
            okButton.isEnabled = false
            cancelButton.isEnabled = false
        }
    }
    
    @IBOutlet weak var titleTextField: NSTextField!
    @IBOutlet weak var textField: NSTextField! {
        didSet {
            textField.delegate = self
            textField.cell?.allowsUndo = false
            textField.placeholderString = Strings.importWalletTextFieldPlaceholder
        }
    }
    
    @IBOutlet weak var cancelButton: NSButton!
    @IBOutlet weak var okButton: NSButton!
    
    isolated deinit {
        validationTask?.cancel()
        importTask?.cancel()
        Window.clearSecretInput(textField)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        cancelButton.title = Strings.cancel
        okButton.title = Strings.ok
        titleTextField.stringValue = Strings.importWallet.replacingOccurrences(of: " ", with: "\n")
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        guard hasCurrentPresentation, walletAccess.beginAction() else { return }
        guard !isImporting else { return }
        if inputValidationResult == .requiresPassword {
            showPasswordAlert()
        } else {
            importWith(input: textField.stringValue, password: nil)
        }
    }
 
    private func showPasswordAlert() {
        guard validateManagementActions() else { return }
        let alert = NSAlert()
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
        passwordTextField.cell?.allowsUndo = false
        passwordTextField.alignment = .center
        
        alert.window.initialFirstResponder = passwordTextField
        passwordPrompt = alert
        defer {
            Window.clearSecretInput(passwordTextField)
            if passwordPrompt === alert { passwordPrompt = nil }
        }
        if dependencies.runPasswordPrompt(alert) == .alertFirstButtonReturn, hasCurrentPresentation, walletAccess.beginAction() {
            let password = passwordTextField.stringValue
            Window.clearSecretInput(passwordTextField)
            importWith(
                input: input,
                password: password
            )
        }
    }

    private func importWith(input: String, password: String?) {
        guard validateManagementActions(), !isImporting else { return }
        isImporting = true
        okButton.isEnabled = false
        let prepareStore = dependencies.prepareStore
        let operation = dependencies.importWallet
        let access = walletAccess
        importTask = Task { [weak self] in
            let result: Result<WalletSnapshot, Error>
            do {
                try Task.checkCancellation()
                guard await prepareStore() else { throw WalletsManager.LoadFailure.unavailable }
                try Task.checkCancellation()
                let session = try access.requireCurrentAccess()
                guard self?.validateManagementActions() == true else { throw CancellationError() }
                self?.cancelButton.isEnabled = false
                result = .success(try await operation(input, password, session))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled, validateManagementActions() else { return }
            importTask = nil
            switch result {
            case .success(let wallet):
                showAccountsList(newWalletId: wallet.id)
            case .failure(let error):
                finishImporting()
                let message: String
                if error is WalletsManager.LoadFailure { message = Strings.failedToLoad }
                else if error as? WalletImportError == .limitExceeded { message = Strings.walletImportLimitExceeded }
                else { message = Strings.failedToImportWallet }
                presentMessageAlert(message, style: .critical)
            }
        }
    }

    private func finishImporting() {
        isImporting = false
        okButton.title = Strings.tryAgain
        okButton.isEnabled = inputValidationResult != .invalid
        cancelButton.isEnabled = true
    }
    

    private func showAccountsList(newWalletId: String?) {
        guard validateManagementActions() else { return }
        guard let window = viewIfLoaded?.window?.windowController as? WalletWindowController else { return }
        let accountsListViewController = AccountsListViewController(access: walletAccess)
        accountsListViewController.newWalletId = newWalletId
        window.installProtectedContent(accountsListViewController, access: walletAccess)
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        guard hasCurrentPresentation, walletAccess.beginAction() else { return }
        showAccountsList(newWalletId: nil)
    }
    
}

extension ImportViewController: NSTextFieldDelegate {
    
    func controlTextDidChange(_ obj: Notification) {
        guard hasCurrentPresentation, walletAccess.beginAction() else { return }
        validationTask?.cancel()
        let input = textField.stringValue
        okButton.title = Strings.ok
        okButton.isEnabled = false
        let validate = dependencies.validate
        validationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await validate(input)
            guard let self, !Task.isCancelled, validateManagementActions(), textField.stringValue == input else { return }
            validationTask = nil
            inputValidationResult = result
            okButton.isEnabled = !isImporting && result != .invalid
        }
    }
    
}
