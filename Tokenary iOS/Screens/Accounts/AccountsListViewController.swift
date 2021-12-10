// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

class AccountsListViewController: UIViewController {
    
    private let walletsManager = WalletsManager.shared
    private let keychain = Keychain.shared
    
    private var wallets: [TokenaryWallet] {
        return walletsManager.wallets
    }
    
    @IBOutlet weak var tableView: UITableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
            tableView.registerReusableCell(type: AccountTableViewCell.self)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = Strings.accounts
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        let addItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addAccount))
        let preferencesItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: UIBarButtonItem.Style.plain, target: self, action: #selector(preferencesButtonTapped))
        navigationItem.rightBarButtonItems = [addItem, preferencesItem]
    }
    
    @objc private func preferencesButtonTapped() {
        let actionSheet = UIAlertController(title: Strings.tokenary, message: nil, preferredStyle: .actionSheet)
        let twitterAction = UIAlertAction(title: Strings.viewOnTwitter, style: .default) { _ in
            UIApplication.shared.open(URL.twitter)
        }
        let githubAction = UIAlertAction(title: Strings.viewOnGithub, style: .default) { _ in
            UIApplication.shared.open(URL.github)
        }
        let emailAction = UIAlertAction(title: Strings.dropUsALine, style: .default) { _ in
            UIApplication.shared.open(URL.email)
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        actionSheet.addAction(twitterAction)
        actionSheet.addAction(githubAction)
        actionSheet.addAction(emailAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    @objc private func addAccount() {
        let actionSheet = UIAlertController(title: Strings.addAccount, message: nil, preferredStyle: .actionSheet)
        let newAccountAction = UIAlertAction(title: "🌱 " + Strings.createNew, style: .default) { [weak self] _ in
            self?.createNewAccount()
        }
        let importAccountAction = UIAlertAction(title: Strings.importExisting, style: .default) { [weak self] _ in
            self?.importExistingAccount()
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        actionSheet.addAction(newAccountAction)
        actionSheet.addAction(importAccountAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    private func createNewAccount() {
        let alert = UIAlertController(title: Strings.backUpNewAccount, message: Strings.youWillSeeSecretWords, preferredStyle: .alert)
        let okAction = UIAlertAction(title: Strings.ok, style: .default) { [weak self] _ in
            self?.createNewAccountAndShowSecretWords()
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        alert.addAction(cancelAction)
        alert.addAction(okAction)
        present(alert, animated: true)
    }
    
    private func createNewAccountAndShowSecretWords() {
        guard let wallet = try? walletsManager.createWallet() else { return }
        tableView.reloadData()
        showKey(wallet: wallet, mnemonic: true)
    }
    
    private func showKey(wallet: TokenaryWallet, mnemonic: Bool) {
        let secret: String
        if mnemonic, let mnemonicString = try? walletsManager.exportMnemonic(wallet: wallet) {
            secret = mnemonicString
        } else if let data = try? walletsManager.exportPrivateKey(wallet: wallet) {
            secret = data.hexString
        } else {
            return
        }
        
        let alert = UIAlertController(title: mnemonic ? Strings.secretWords : Strings.privateKey, message: secret, preferredStyle: .alert)
        let okAction = UIAlertAction(title: Strings.ok, style: .default)
        let cancelAction = UIAlertAction(title: Strings.copy, style: .default) { _ in
            UIPasteboard.general.string = secret
        }
        alert.addAction(cancelAction)
        alert.addAction(okAction)
        present(alert, animated: true)
    }
    
    private func importExistingAccount() {
        let importAccountViewController = instantiate(ImportViewController.self, from: .main)
        importAccountViewController.completion = { [weak self] success in
            if success {
                self?.tableView.reloadData()
            }
        }
        present(importAccountViewController.inNavigationController, animated: true)
    }
    
    private func showActionsForWallet(_ wallet: TokenaryWallet) {
        let address = wallet.ethereumAddress ?? ""
        let actionSheet = UIAlertController(title: address, message: nil, preferredStyle: .actionSheet)
        
        let copyAddressAction = UIAlertAction(title: Strings.copyAddress, style: .default) { _ in
            UIPasteboard.general.string = address
        }
        
        let etherscanAction = UIAlertAction(title: Strings.viewOnEtherscan, style: .default) { _ in
            UIApplication.shared.open(URL.etherscan(address: address))
        }
        
        let showKeyAction = UIAlertAction(title: Strings.showAccountKey, style: .default) { [weak self] _ in
            self?.didTapExportAccount(wallet)
        }
        
        let removeAction = UIAlertAction(title: Strings.removeAccount, style: .destructive) { [weak self] _ in
            self?.didTapRemoveAccount(wallet)
        }
        
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        
        actionSheet.addAction(copyAddressAction)
        actionSheet.addAction(etherscanAction)
        actionSheet.addAction(showKeyAction)
        actionSheet.addAction(removeAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    private func didTapRemoveAccount(_ wallet: TokenaryWallet) {
        askBeforeRemoving(wallet: wallet)
    }
    
    private func askBeforeRemoving(wallet: TokenaryWallet) {
        let alert = UIAlertController(title: Strings.removedAccountsCantBeRecovered, message: nil, preferredStyle: .alert)
        let removeAction = UIAlertAction(title: Strings.removeAnyway, style: .destructive) { [weak self] _ in
            LocalAuthentication.attempt(reason: Strings.removeAccount) { success in
                if success {
                    self?.removeWallet(wallet)
                } else {
                    self?.showPasswordAlert(title: Strings.enterPassword, message: Strings.toRemoveAccount) { password in
                        if password == self?.keychain.password {
                            self?.removeWallet(wallet)
                        } else {
                            self?.showMessageAlert(text: Strings.passwordDoesNotMatch)
                        }
                    }
                }
            }
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        alert.addAction(cancelAction)
        alert.addAction(removeAction)
        present(alert, animated: true)
    }
    
    private func removeWallet(_ wallet: TokenaryWallet) {
        try? walletsManager.delete(wallet: wallet)
        tableView.reloadData()
    }
    
    private func didTapExportAccount(_ wallet: TokenaryWallet) {
        let isMnemonic = wallet.isMnemonic
        let title = isMnemonic ? Strings.secretWordsGiveFullAccess : Strings.privateKeyGivesFullAccess
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        let okAction = UIAlertAction(title: Strings.iUnderstandTheRisks, style: .default) { [weak self] _ in
            LocalAuthentication.attempt(reason: Strings.removeAccount) { success in
                if success {
                    self?.showKey(wallet: wallet, mnemonic: isMnemonic)
                } else {
                    self?.showPasswordAlert(title: Strings.enterPassword, message: Strings.toShowAccountKey) { password in
                        if password == self?.keychain.password {
                            self?.showKey(wallet: wallet, mnemonic: isMnemonic)
                        } else {
                            self?.showMessageAlert(text: Strings.passwordDoesNotMatch)
                        }
                    }
                }
            }
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        alert.addAction(cancelAction)
        alert.addAction(okAction)
        present(alert, animated: true)
    }
    
}


extension AccountsListViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            askBeforeRemoving(wallet: wallets[indexPath.row])
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        showActionsForWallet(wallets[indexPath.row])
    }
    
}

extension AccountsListViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return walletsManager.wallets.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellOfType(AccountTableViewCell.self, for: indexPath)
        let wallet = wallets[indexPath.row]
        cell.setup(address: wallet.ethereumAddress ?? "", delegate: self)
        return cell
    }
    
}

extension AccountsListViewController: AccountTableViewCellDelegate {
    
    func didTapMoreButton(accountCell: AccountTableViewCell) {
        guard let index = tableView.indexPath(for: accountCell)?.row else { return }
        showActionsForWallet(wallets[index])
    }
    
}
