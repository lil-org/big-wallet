// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

class ImportViewController: UIViewController {
    private let walletsManager = WalletsManager.shared
    
    @IBOutlet weak var placeholderLabel: UILabel! {
        didSet {
            placeholderLabel.text = Strings.importAccountTextFieldPlaceholder
        }
    }
    @IBOutlet weak var pasteButton: UIButton!
    @IBOutlet weak var okButton: UIButton!
    @IBOutlet weak var textView: UITextView! {
        didSet {
            textView.delegate = self
            textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
            textView.layer.cornerRadius = 5
            textView.layer.borderWidth = CGFloat.pixel
            textView.layer.borderColor = UIColor.separator.cgColor
        }
    }
    
    private var isWaiting = false
    private var inputValidationResult = InputValidationResult1.invalidData
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.title = Strings.importAccount
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(dismissAnimated))
        
        okButton.configurationUpdateHandler = { [weak self] button in
            let isWaiting = self?.isWaiting == true
            button.configuration?.title = isWaiting ? .empty : Strings.ok
            button.configuration?.showsActivityIndicator = isWaiting
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.main.async { [weak self] in
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
    
    private func setLoading(_ waiting: Bool) {
        guard waiting != self.isWaiting else { return }
        self.isWaiting = waiting
        view.isUserInteractionEnabled = !waiting
        isModalInPresentation = waiting
        navigationItem.leftBarButtonItem?.isEnabled = !waiting
        okButton.setNeedsUpdateConfiguration()
    }
    
    private func validateInput(proceedIfValid: Bool) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        self.inputValidationResult = self.walletsManager.getValidationFor(input: self.textView.text)
        let isValid = ![
            InputValidationResult1.invalidData, InputValidationResult1.alreadyPresent
        ].contains(self.inputValidationResult)
        okButton.isEnabled = isValid
        if isValid && proceedIfValid {
            attemptImportWithCurrentInput()
        }
    }
    
    private func attemptImportWithCurrentInput() {
        if self.inputValidationResult == .passwordProtectedJSON {
            self.askForPassword()
        } else if let walletDerivationType = inputValidationResult.walletDerivationType {
            self.selectCoins(input: textView.text, derivationType: walletDerivationType)
        }
    }
    
    private func askForPassword() {
        showPasswordAlert(
            title: Strings.ImportViewController.enterPasswordAlertTitle,
            message: Strings.ImportViewController.enterPasswordAlertDescription
        ) { [weak self] password in
            guard let password = password else { return }
            self?.setLoading(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
                guard let self = self else { return }
                self.validatePasswordProtectedInput(input: self.textView.text, password: password)
            }
        }
    }
    
    private func validatePasswordProtectedInput(input: String, password: String) {
        let (inputValidationResult, decryptedInput) = self.walletsManager.decryptJSONAndValidate(
            input: input, password: password
        )
        self.setLoading(false)
        if let decryptedInput = decryptedInput, let walletDerivationType = inputValidationResult.walletDerivationType {
            self.selectCoins(input: decryptedInput, derivationType: walletDerivationType)
        } else {
            self.showMessageAlert(text: Strings.ImportViewController.couldNotDecryptProtectedDataAlertTitle)
        }
    }
    
    private func selectCoins(input: String, derivationType: InputValidationResult1.WalletDerivationType) {
        let possibleCoinTypes = derivationType.supportedCoinTypes
        let accountSelectionVC = AccountSelectionAssembly.build(
            for: derivationType == .mnemonic ? .multiSelect(possibleCoinTypes) : .singleSelect(possibleCoinTypes),
            completion: { [weak self] selectedCoinTypes in
                self?.importWallet(input: input, coinTypes: selectedCoinTypes)
            }
        )
        accountSelectionVC.modalPresentationStyle = .formSheet
        present(accountSelectionVC, animated: true)
    }
    
    private func importWallet(input: String, coinTypes: [SupportedCoinType]) {
        do {
            try self.walletsManager.addWallet(input: input, coinTypes: coinTypes)
            self.presentingViewController?.dismissAnimated()
        } catch {
            self.setLoading(false)
            self.showMessageAlert(text: Strings.failedToImportAccount)
            dismissAnimated()
        }
    }
}

// MARK: ImportViewController + UITextViewDelegate

extension ImportViewController: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == Symbols.newLine {
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
