// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

class AccountsListViewController: UIViewController, DataStateContainer {
    
    private let walletsManager = WalletsManager.shared
    private let keychain = Keychain.shared
    private let ethereum = Ethereum.shared
    
    private var chain = EthereumChain.ethereum
    var onSelectedWallet: ((EthereumChain?, TokenaryWallet?) -> Void)?
    var forWalletSelection: Bool {
        return onSelectedWallet != nil
    }
    
    private var wallets: [TokenaryWallet] {
        return walletsManager.wallets
    }
    
    @IBOutlet weak var chainButton: UIButton!
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
        
        let peerMeta = PeerMeta(title: request.host, iconURLString: request.iconURLString)
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
            presentForSafariRequest(selectAccountViewController.inNavigationController)
        case .signTypedMessage:
            guard let raw = request.raw,
                  let wallet = walletsManager.getWallet(address: request.address),
                  let address = wallet.ethereumAddress else {
                respondTo(request: request, error: Strings.somethingWentWrong)
                return
            }
            showApprove(subject: .signTypedData, address: address, meta: raw, peerMeta: peerMeta) { [weak self] approved in
                if approved {
                    self?.signTypedData(wallet: wallet, raw: raw, request: request)
                } else {
                    self?.respondTo(request: request, error: Strings.failedToSign)
                }
            }
        case .signMessage:
            guard let data = request.message,
                  let wallet = walletsManager.getWallet(address: request.address),
                  let address = wallet.ethereumAddress else {
                respondTo(request: request, error: Strings.somethingWentWrong)
                return
            }
            showApprove(subject: .signMessage, address: address, meta: data.hexString, peerMeta: peerMeta) { [weak self] approved in
                if approved {
                    self?.signMessage(wallet: wallet, data: data, request: request)
                } else {
                    self?.respondTo(request: request, error: Strings.failedToSign)
                }
            }
        case .signPersonalMessage:
            guard let data = request.message,
                  let wallet = walletsManager.getWallet(address: request.address),
                  let address = wallet.ethereumAddress else {
                respondTo(request: request, error: Strings.somethingWentWrong)
                return
            }
            let text = String(data: data, encoding: .utf8) ?? data.hexString
            showApprove(subject: .signPersonalMessage, address: address, meta: text, peerMeta: peerMeta) { [weak self] approved in
                if approved {
                    self?.signPersonalMessage(wallet: wallet, data: data, request: request)
                } else {
                    self?.respondTo(request: request, error: Strings.failedToSign)
                }
            }
        case .signTransaction:
            guard let transaction = request.transaction,
                  let chain = request.chain,
                  let wallet = walletsManager.getWallet(address: request.address),
                  let address = wallet.ethereumAddress else {
                      respondTo(request: request, error: Strings.somethingWentWrong)
                      return
                  }
            showApprove(transaction: transaction, chain: chain, address: address, peerMeta: peerMeta) { [weak self] transaction in
                if let transaction = transaction {
                    self?.sendTransaction(wallet: wallet, transaction: transaction, chain: chain, request: request)
                } else {
                    self?.respondTo(request: request, error: Strings.canceled)
                }
            }
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
    
    func showApprove(transaction: Transaction, chain: EthereumChain, address: String, peerMeta: PeerMeta?, completion: @escaping (Transaction?) -> Void) {
        let approveTransactionViewController = ApproveTransactionViewController.with(transaction: transaction,
                                                                                     chain: chain,
                                                                                     address: address,
                                                                                     peerMeta: peerMeta,
                                                                                     completion: completion)
        presentForSafariRequest(approveTransactionViewController.inNavigationController)
    }
    
    func showApprove(subject: ApprovalSubject, address: String, meta: String, peerMeta: PeerMeta?, completion: @escaping (Bool) -> Void) {
        let approveViewController = ApproveViewController.with(subject: subject, address: address, meta: meta, peerMeta: peerMeta, completion: completion)
        presentForSafariRequest(approveViewController.inNavigationController)
    }
    
    private func presentForSafariRequest(_ viewController: UIViewController) {
        // TODO: present above all
        present(viewController, animated: true)
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
    
    @IBAction func chainButtonTapped(_ sender: Any) {
        let actionSheet = UIAlertController(title: Strings.selectNetwork, message: nil, preferredStyle: .actionSheet)
        for chain in EthereumChain.allMainnets {
            let action = UIAlertAction(title: chain.name, style: .default) { [weak self] _ in
                self?.didSelectChain(chain)
            }
            actionSheet.addAction(action)
        }
        let testnetsAction = UIAlertAction(title: Strings.testnets.withEllipsis, style: .default) { [weak self] _ in
            self?.showTestnets()
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        actionSheet.addAction(testnetsAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    private func showTestnets() {
        let actionSheet = UIAlertController(title: Strings.selectTestnet, message: nil, preferredStyle: .actionSheet)
        for chain in EthereumChain.allTestnets {
            let action = UIAlertAction(title: chain.name, style: .default) { [weak self] _ in
                self?.didSelectChain(chain)
            }
            actionSheet.addAction(action)
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    private func didSelectChain(_ chain: EthereumChain) {
        chainButton.configuration?.title = chain.name
        self.chain = chain
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
    
    private func signPersonalMessage(wallet: TokenaryWallet, data: Data, request: SafariRequest) {
        if let signed = try? ethereum.signPersonalMessage(data: data, wallet: wallet) {
            let response = ResponseToExtension(name: request.name, result: signed)
            respondTo(request: request, response: response)
        } else {
            respondTo(request: request, error: Strings.failedToSign)
        }
    }
    
    private func signTypedData(wallet: TokenaryWallet, raw: String, request: SafariRequest) {
        if let signed = try? ethereum.sign(typedData: raw, wallet: wallet) {
            let response = ResponseToExtension(name: request.name, result: signed)
            respondTo(request: request, response: response)
        } else {
            respondTo(request: request, error: Strings.failedToSign)
        }
    }
    
    private func signMessage(wallet: TokenaryWallet, data: Data, request: SafariRequest) {
        if let signed = try? ethereum.sign(data: data, wallet: wallet) {
            let response = ResponseToExtension(name: request.name, result: signed)
            respondTo(request: request, response: response)
        } else {
            respondTo(request: request, error: Strings.failedToSign)
        }
    }
    
    private func sendTransaction(wallet: TokenaryWallet, transaction: Transaction, chain: EthereumChain, request: SafariRequest) {
        if let transactionHash = try? ethereum.send(transaction: transaction, wallet: wallet, chain: chain) {
            let response = ResponseToExtension(name: request.name, result: transactionHash)
            respondTo(request: request, response: response)
        } else {
            respondTo(request: request, error: Strings.failedToSend)
        }
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
            onSelectedWallet?(chain, wallet)
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
