// ∅ 2026 lil org

import Cocoa

class ImportViewController: NSViewController {
    
    private let walletsManager = WalletsManager.shared
    var accountSelection: NativeAccountSelectionSession?
    private var inputValidationResult = WalletsManager.InputValidationResult.invalid
    private var presentedPasswordAlert: (alert: NSAlert, token: UUID)?
    private var isNativeApprovalReviewInvalidated = false
    
    @IBOutlet weak var titleTextField: NSTextField!
    @IBOutlet weak var textField: NSTextField! {
        didSet {
            textField.delegate = self
            textField.placeholderString = Strings.importWalletTextFieldPlaceholder
        }
    }
    
    @IBOutlet weak var cancelButton: NSButton!
    @IBOutlet weak var okButton: NSButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        cancelButton.title = Strings.cancel
        okButton.title = Strings.ok
        titleTextField.stringValue = Strings.importWallet.replacingOccurrences(of: " ", with: "\n")
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        if inputValidationResult == .requiresPassword {
            showPasswordAlert()
        } else {
            importWith(input: textField.stringValue, password: nil)
        }
    }
 
    private func showPasswordAlert() {
        guard presentedPasswordAlert == nil,
              let window = view.window else { return }
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
        
        guard nativeApprovalPeer != nil else {
            DispatchQueue.main.async { [weak passwordTextField] in
                passwordTextField?.becomeFirstResponder()
            }
            if alert.runModal() == .alertFirstButtonReturn {
                importWith(
                    input: input,
                    password: passwordTextField.stringValue
                )
            }
            return
        }
        
        let token = UUID()
        presentedPasswordAlert = (alert, token)

        DispatchQueue.main.async { [weak self, weak passwordTextField] in
            guard self?.presentedPasswordAlert?.token == token else { return }
            passwordTextField?.becomeFirstResponder()
        }

        alert.beginSheetModal(for: window) {
            [weak self, weak alert, weak passwordTextField] response in
            guard let self, let alert, let passwordTextField,
                  presentedPasswordAlert?.alert === alert,
                  presentedPasswordAlert?.token == token else { return }
            presentedPasswordAlert = nil
            guard !isNativeApprovalReviewInvalidated,
                  response == .alertFirstButtonReturn else { return }
            importWith(
                input: input,
                password: passwordTextField.stringValue
            )
        }
    }

    private func dismissPasswordAlert() {
        guard let presentedPasswordAlert else { return }
        self.presentedPasswordAlert = nil
        if let parent = presentedPasswordAlert.alert.window.sheetParent {
            parent.endSheet(
                presentedPasswordAlert.alert.window,
                returnCode: .abort
            )
        }
        presentedPasswordAlert.alert.window.orderOut(nil)
    }
    
    private func importWith(input: String, password: String?) {
        do {
            let wallet = try walletsManager.addWallet(input: input, inputPassword: password)
            showAccountsList(newWalletId: wallet.id)
        } catch {
            presentMessageAlert(Strings.failedToImportWallet, style: .critical)
        }
    }
    
    private func showAccountsList(newWalletId: String?) {
        let accountsListViewController = instantiate(AccountsListViewController.self)
        accountsListViewController.accountSelection = accountSelection
        accountsListViewController.newWalletId = newWalletId
        view.window?.contentViewController = accountsListViewController
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        showAccountsList(newWalletId: nil)
    }
    
}

extension ImportViewController: NativeApprovalReviewTeardown {

    func invalidateNativeApprovalReview() {
        guard !isNativeApprovalReviewInvalidated else { return }
        isNativeApprovalReviewInvalidated = true
        dismissPasswordAlert()
        endAllSheets()
    }

}

extension ImportViewController: NSTextFieldDelegate {
    
    func controlTextDidChange(_ obj: Notification) {
        inputValidationResult = walletsManager.validateWalletInput(textField.stringValue)
        okButton.isEnabled = inputValidationResult != .invalid
    }
    
}
