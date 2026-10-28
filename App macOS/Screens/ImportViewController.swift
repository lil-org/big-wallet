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
        var importWallet: @MainActor (String, String?, WalletAccessSession) async throws -> WalletSnapshot = {
            try await ApplicationServices.shared.wallets.addWallet(input: $0, inputPassword: $1, access: $2)
        }
        var runPasswordPrompt: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    }

    var walletAccess = NativeWalletAccess()
    var dependencies = Dependencies()
    private var validationTask: Task<Void, Never>?
    private var importTask: Task<WalletSnapshot, Error>?
    private var importResultTask: Task<Void, Never>?
    private var retirementCheckTask: Task<Void, Never>?
    private var closeObserver: NativeApprovalWindowCloseObserver?
    private var inputValidationResult = WalletsManager.InputValidationResult.invalid
    private var isImporting = false
    private var isRetired = false
    private var passwordPrompt: NSAlert?
    private var acceptsManagementActions: Bool {
        !isRetired && walletAccess.isCurrent && viewIfLoaded?.window?.contentViewController === self
    }

    func retireForWalletLock() {
        retireImport()
    }

    private func retireImport() {
        guard !isRetired else { return }
        isRetired = true
        validationTask?.cancel()
        validationTask = nil
        importTask?.cancel()
        importTask = nil
        importResultTask?.cancel()
        importResultTask = nil
        retirementCheckTask?.cancel()
        retirementCheckTask = nil
        closeObserver?.disable()
        closeObserver = nil
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
        importResultTask?.cancel()
        retirementCheckTask?.cancel()
        closeObserver?.disable()
        Window.clearSecretInput(textField)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if viewIfLoaded?.window?.contentViewController !== self { retireImport() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        retirementCheckTask?.cancel()
        retirementCheckTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled,
                  viewIfLoaded?.window?.contentViewController !== self else { return }
            retireImport()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        retirementCheckTask?.cancel()
        retirementCheckTask = nil
        guard !isRetired, let window = viewIfLoaded?.window else { return }
        closeObserver?.disable()
        let observer = NativeApprovalWindowCloseObserver { [weak self] in self?.retireImport() }
        closeObserver = observer
        observer.observe(window)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        cancelButton.title = Strings.cancel
        okButton.title = Strings.ok
        titleTextField.stringValue = Strings.importWallet.replacingOccurrences(of: " ", with: "\n")
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions, !isImporting else { return }
        if inputValidationResult == .requiresPassword {
            showPasswordAlert()
        } else {
            importWith(input: textField.stringValue, password: nil)
        }
    }
 
    private func showPasswordAlert() {
        guard acceptsManagementActions else { return }
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
        if dependencies.runPasswordPrompt(alert) == .alertFirstButtonReturn, acceptsManagementActions, walletAccess.beginAction() {
            let password = passwordTextField.stringValue
            Window.clearSecretInput(passwordTextField)
            importWith(
                input: input,
                password: password
            )
        }
    }

    private func importWith(input: String, password: String?) {
        guard acceptsManagementActions, !isImporting else { return }
        isImporting = true
        okButton.isEnabled = false
        cancelButton.isEnabled = false
        let operation = dependencies.importWallet
        let access = walletAccess
        let task = Task {
            try Task.checkCancellation()
            let session = try access.requireCurrentAccess()
            return try await operation(input, password, session)
        }
        importTask = task
        importResultTask = Task { [weak self] in
            let result = await task.result
            guard let self, !Task.isCancelled, acceptsManagementActions else { return }
            importTask = nil
            importResultTask = nil
            switch result {
            case .success(let wallet):
                showAccountsList(newWalletId: wallet.id)
            case .failure(let error):
                finishImporting()
                presentMessageAlert(error as? WalletImportError == .limitExceeded
                    ? Strings.walletImportLimitExceeded : Strings.failedToImportWallet, style: .critical)
            }
        }
    }

    private func finishImporting() {
        isImporting = false
        okButton.isEnabled = inputValidationResult != .invalid
        cancelButton.isEnabled = true
    }
    

    private func showAccountsList(newWalletId: String?) {
        guard acceptsManagementActions else { return }
        let destination = viewIfLoaded?.window
        let access = walletAccess
        retireImport()
        let accountsListViewController = AccountsListViewController()
        accountsListViewController.walletAccess = access
        accountsListViewController.newWalletId = newWalletId
        if let window = destination?.windowController as? WalletWindowController {
            window.installProtectedContent(accountsListViewController, access: access)
        } else {
            guard access.isCurrent else { return }
            destination?.contentViewController = accountsListViewController
        }
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions else { return }
        showAccountsList(newWalletId: nil)
    }
    
}

extension ImportViewController: NSTextFieldDelegate {
    
    func controlTextDidChange(_ obj: Notification) {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions else { return }
        validationTask?.cancel()
        let input = textField.stringValue
        okButton.isEnabled = false
        let validate = dependencies.validate
        validationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await validate(input)
            guard let self, !Task.isCancelled, acceptsManagementActions, textField.stringValue == input else { return }
            validationTask = nil
            inputValidationResult = result
            okButton.isEnabled = !isImporting && result != .invalid
        }
    }
    
}
