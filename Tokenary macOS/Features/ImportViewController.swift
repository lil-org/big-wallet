// Copyright © 2021 Tokenary. All rights reserved.

import AppKit

class ImportViewController: NSViewController {
    private let walletsManager = WalletsManager.shared
    
    @IBOutlet weak var textField: NSTextField! {
        didSet {
            self.textField.delegate = self
            self.textField.placeholderString = Strings.importAccountTextFieldPlaceholder
        }
    }
    @IBOutlet weak var okButton: NSButton!
    
    var onSelectedWallet: ((EthereumChain?, TokenaryWallet?) -> Void)?
    private var inputValidationResult = WalletsManager.InputValidationResult.invalidData

    @IBAction func okButtonTapped(_ sender: Any) {
        if self.inputValidationResult == .passwordProtectedJSON {
            self.askForPassword()
        } else if let walletKeyType = self.inputValidationResult.walletKeyType {
            self.selectChains(input: self.textField.stringValue, walletKeyType: walletKeyType)
        }
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        self.showAccountsList(newWalletId: nil)
    }

    private func askForPassword() {
        Alert.showPasswordAlert(
            title: Strings.enterKeystorePassword
        ) { [weak self] password in
            guard
                let self = self,
                let password = password
            else { return }
            self.validatePasswordProtectedInput(input: self.textField.stringValue, password: password)
        }
    }
    
    private func validatePasswordProtectedInput(input: String, password: String) {
        let (inputValidationResult, decryptedInput) = self.walletsManager.decryptJSONAndValidate(
            input: input, password: password
        )
        if let decryptedInput = decryptedInput, let walletKeyType = inputValidationResult.walletKeyType {
            self.selectChains(input: decryptedInput, walletKeyType: walletKeyType)
        } else {
            Alert.showWithMessage(
                Strings.ImportViewController.couldNotDecryptProtectedDataAlertTitle, style: .critical
            )
        }
    }
    
    private func selectChains(input: String, walletKeyType: WalletsManager.InputValidationResult.WalletKeyType) {
        let possibleChainTypes = walletKeyType.supportedChainTypes
        let chainSelectionVC = ChainSelectionAssembly.build(
            for: walletKeyType == .mnemonic ? .multiSelect(possibleChainTypes) : .singleSelect(possibleChainTypes),
            completion: { [self] selectedChains in
                if selectedChains.count != .zero {
                    self.importWallet(input: input, chainTypes: selectedChains)
                } else {
                    self.processErrorOrCancel()
                }
            }
        )
        view.window?.contentViewController = chainSelectionVC
    }
    
    private func importWallet(input: String, chainTypes: [ChainType]) {
        do {
            let createdWallet = try self.walletsManager.addWallet(input: input, chainTypes: chainTypes)
            self.showAccountsList(newWalletId: createdWallet.id)
        } catch {
            self.processErrorOrCancel(showAlert: true)
        }
    }
    
    private func processErrorOrCancel(showAlert: Bool = false) {
        let newWindow = Window.showNew()
        newWindow.contentViewController = self
        if showAlert {
            Alert.showWithMessage(Strings.failedToImportAccount, style: .critical)
        }
    }
    
    private func showAccountsList(newWalletId: String?) {
        let accountsListVC = AccountsListAssembly.build(
            for: .mainScreen, newWalletId: newWalletId, onSelectedWallet: onSelectedWallet
        )
        let newWindow = Window.showNew()
        newWindow.contentViewController = accountsListVC
    }
}

extension ImportViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        self.inputValidationResult = self.walletsManager.getValidationFor(input: self.textField.stringValue)
        let isValid = ![
            WalletsManager.InputValidationResult.invalidData, WalletsManager.InputValidationResult.alreadyPresent
        ].contains(self.inputValidationResult)
        okButton.isEnabled = isValid
    }
}
