// Copyright © 2021 Tokenary. All rights reserved.

import AppKit

class ImportViewController: NSViewController {
    private let walletsManager = WalletsManager.shared
    
    @IBOutlet weak var textField: NSTextField! {
        didSet {
            textField.delegate = self
            textField.placeholderString = Strings.importAccountTextFieldPlaceholder
        }
    }
    @IBOutlet weak var okButton: NSButton!
    
    var accountsListVC: AccountsListViewController?
    
    var onSelectedWallet: ((EthereumChain?, TokenaryWallet?) -> Void)?
    private var inputValidationResult = WalletsManager.InputValidationResult.invalidData

    @IBAction func okButtonTapped(_ sender: Any) {
        if inputValidationResult == .passwordProtectedJSON {
            askForPassword()
        } else if let walletKeyType = inputValidationResult.walletKeyType {
            selectChains(input: textField.stringValue, walletKeyType: walletKeyType)
        }
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        showAccountsList(newWalletId: nil)
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
        let (inputValidationResult, decryptedInput) = walletsManager.decryptJSONAndValidate(
            input: input, password: password
        )
        if let decryptedInput = decryptedInput, let walletKeyType = inputValidationResult.walletKeyType {
            selectChains(input: decryptedInput, walletKeyType: walletKeyType)
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
            let createdWallet = try walletsManager.addWallet(input: input, chainTypes: chainTypes)
            showAccountsList(newWalletId: createdWallet.id)
        } catch {
            processErrorOrCancel(showAlert: true)
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
        accountsListVC?.newWalletId = newWalletId
        let newWindow = Window.showNew()
        newWindow.contentViewController = accountsListVC
    }
}

extension ImportViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        inputValidationResult = walletsManager.getValidationFor(input: textField.stringValue)
        let isValid = ![
            WalletsManager.InputValidationResult.invalidData, WalletsManager.InputValidationResult.alreadyPresent
        ].contains(inputValidationResult)
        okButton.isEnabled = isValid
    }
}
