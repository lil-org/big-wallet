// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

class AccountsListViewController: UIViewController, DataStateContainer {
    
    private let walletsManager = WalletsManager.shared
    private let keychain = Keychain.shared
    
    var onSelectedWallet: ((EthereumChain?, TokenaryWallet?) -> Void)?
    var forWalletSelection: Bool {
        return onSelectedWallet != nil
    }
    
    private var wallets: [TokenaryWallet] {
        return walletsManager.wallets
    }
    
    @IBOutlet weak var chainSelectionHeader: UIView!
    @IBOutlet weak var tableView: UITableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
            tableView.registerReusableCell(type: AccountTableViewCell.self)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = forWalletSelection ? Strings.selectAccount : Strings.accounts
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        isModalInPresentation = true
        let addItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addAccount))
        let preferencesItem = UIBarButtonItem(image: Images.preferences, style: UIBarButtonItem.Style.plain, target: self, action: #selector(preferencesButtonTapped))
        let cancelItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelButtonTapped))
        navigationItem.rightBarButtonItems = forWalletSelection ? [addItem] : [addItem, preferencesItem]
        if forWalletSelection {
            navigationItem.leftBarButtonItem = cancelItem
        }
        configureDataState(.noData, description: Strings.tokenaryIsEmpty, buttonTitle: Strings.addAccount) { [weak self] in
            self?.addAccount()
        }
        dataStateShouldMoveWithKeyboard(false)
        updateDataState()
        NotificationCenter.default.addObserver(self, selector: #selector(processInput), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: Notification.Name.walletsChanged, object: nil)
        if !forWalletSelection {
            hideChainSelectionHeader()
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        processInput()
        DispatchQueue.main.async { [weak self] in
            self?.navigationController?.navigationBar.sizeToFit()
        }
    }
    
    @objc private func processInput() {
        let prefix = "tokenary://"
        guard let url = launchURL?.absoluteString, url.hasPrefix(prefix),
              let request = SafariRequest(query: String(url.dropFirst(prefix.count))) else { return }
        launchURL = nil
        
        switch request.method {
        case .switchAccount, .requestAccounts:
            let selectAccountViewController = instantiate(AccountsListViewController.self, from: .main)
            selectAccountViewController.onSelectedWallet = { [weak self] (chain, wallet) in
                guard let chain = chain, let address = wallet?.ethereumAddress else {
                    self?.respondTo(request: request, error: Strings.canceled)
                    return
                }
                let response = ResponseToExtension(name: request.name,
                                                   results: [address],
                                                   chainId: chain.hexStringId,
                                                   rpcURL: chain.nodeURLString)
                self?.respondTo(request: request, response: response)
            }
            present(selectAccountViewController.inNavigationController, animated: true)
        default:
            showMessageAlert(text: request.name) { [weak self] in
                let chain = EthereumChain.ethereum
                let response = ResponseToExtension(name: request.name,
                                                   results: ["0xE26067c76fdbe877F48b0a8400cf5Db8B47aF0fE"],
                                                   chainId: chain.hexStringId,
                                                   rpcURL: chain.nodeURLString)
                self?.respondTo(request: request, response: response)
            }
        }
    }
    
    private func respondTo(request: SafariRequest, response: ResponseToExtension) {
        ExtensionBridge.respond(id: request.id, response: response)
        UIApplication.shared.open(URL.blankRedirect(id: request.id))
    }
    
    private func respondTo(request: SafariRequest, error: String) {
        let response = ResponseToExtension(name: request.name, error: error)
        respondTo(request: request, response: response)
    }
    
    private func hideChainSelectionHeader() {
        chainSelectionHeader.isHidden = true
        chainSelectionHeader.frame = CGRect(origin: CGPoint.zero, size: CGSize.zero)
    }
    
    @objc private func cancelButtonTapped() {
        onSelectedWallet?(nil, nil)
        dismissAnimated()
    }
    
    @objc private func walletsChanged() {
        reloadData()
    }
    
    private func updateDataState() {
        let isEmpty = wallets.isEmpty
        dataState = isEmpty ? .noData : .hasData
        let canScroll = !isEmpty
        if tableView.isScrollEnabled != canScroll {
            tableView.isScrollEnabled = canScroll
        }
    }
    
    private func reloadData() {
        updateDataState()
        tableView.reloadData()
    }
    
    @objc private func preferencesButtonTapped() {
        let actionSheet = UIAlertController(title: "❤️ " + Strings.tokenary + " ❤️", message: nil, preferredStyle: .actionSheet)
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
        reloadData()
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
        reloadData()
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
        let wallet = wallets[indexPath.row]
        if forWalletSelection {
            onSelectedWallet?(EthereumChain.ethereum, wallet) // TODO: use picked chain
            dismissAnimated()
        } else {
            showActionsForWallet(wallet)
        }
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
