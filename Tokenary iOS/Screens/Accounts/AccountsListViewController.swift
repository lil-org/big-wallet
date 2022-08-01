// Copyright © 2021 Tokenary. All rights reserved.

import UIKit
import WalletCore

class AccountsListViewController: UIViewController, DataStateContainer {
    
    enum Section {
        case privateKeyWallets(cellModels: [CellModel])
        case mnemonicWallet(cellModels: [CellModel])
        
        var items: [CellModel] {
            switch self {
            case let .mnemonicWallet(cellModels: cellModels):
                return cellModels
            case let .privateKeyWallets(cellModels: cellModels):
                return cellModels
            }
        }
    }
    
    enum CellModel {
        case mnemonicAccount(walletIndex: Int, accountIndex: Int)
        case privateKeyAccount(walletIndex: Int)
    }
    
    private var sections = [Section]()
    private let walletsManager = WalletsManager.shared
    
    private var chain = EthereumChain.ethereum
    var onSelectedWallet: ((EthereumChain?, TokenaryWallet?, Account?) -> Void)?
    var forWalletSelection: Bool {
        return onSelectedWallet != nil
    }
    
    private var wallets: [TokenaryWallet] {
        return walletsManager.wallets
    }
    
    private var toDismissAfterResponse = [Int: UIViewController]()
    private var preferencesItem: UIBarButtonItem?
    private var addWalletItem: UIBarButtonItem?
    
    @IBOutlet weak var selectNetworkButtonContainer: UIVisualEffectView!
    @IBOutlet weak var selectNetworkButton: UIButton!
    @IBOutlet weak var tableView: UITableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
            tableView.registerReusableCell(type: AccountTableViewCell.self)
            tableView.registerReusableHeaderFooter(type: AccountsHeaderView.self)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if walletsManager.wallets.isEmpty {
            walletsManager.start()
        }
        
        navigationItem.title = forWalletSelection ? Strings.selectAccount : Strings.wallets
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        isModalInPresentation = true
        let addItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addWallet))
        let preferencesItem = UIBarButtonItem(image: Images.preferences, style: UIBarButtonItem.Style.plain, target: self, action: #selector(preferencesButtonTapped))
        let cancelItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelButtonTapped))
        self.addWalletItem = addItem
        self.preferencesItem = preferencesItem
        navigationItem.rightBarButtonItems = forWalletSelection ? [addItem] : [addItem, preferencesItem]
        if forWalletSelection {
            navigationItem.leftBarButtonItem = cancelItem
        }
        configureDataState(.noData, description: Strings.tokenaryIsEmpty, buttonTitle: Strings.addWallet) { [weak self] in
            self?.addWallet()
        }
        dataStateShouldMoveWithKeyboard(false)
        updateCellModels()
        updateDataState()
        NotificationCenter.default.addObserver(self, selector: #selector(processInput), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: Notification.Name.walletsChanged, object: nil)
        if forWalletSelection {
            selectNetworkButtonContainer.isHidden = false
            let bottomOverlayHeight: CGFloat = 52
            tableView.contentInset.bottom += bottomOverlayHeight
            tableView.verticalScrollIndicatorInsets.bottom += bottomOverlayHeight
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        processInput()
        DispatchQueue.main.async { [weak self] in
            self?.navigationController?.navigationBar.sizeToFit()
        }
    }
    
    private func walletForIndexPath(_ indexPath: IndexPath) -> TokenaryWallet {
        let item = sections[indexPath.section].items[indexPath.row]
        switch item {
        case let .mnemonicAccount(walletIndex: walletIndex, accountIndex: _):
            return wallets[walletIndex]
        case let .privateKeyAccount(walletIndex: walletIndex):
            return wallets[walletIndex]
        }
    }
    
    private func accountForIndexPath(_ indexPath: IndexPath) -> Account {
        let item = sections[indexPath.section].items[indexPath.row]
        switch item {
        case let .mnemonicAccount(walletIndex: walletIndex, accountIndex: accountIndex):
            return wallets[walletIndex].accounts[accountIndex]
        case let .privateKeyAccount(walletIndex: walletIndex):
            return wallets[walletIndex].accounts[0]
        }
    }
    
    private func updateCellModels() {
        sections = []
        var privateKeyAccountCellModels = [CellModel]()
        
        for index in 0..<wallets.count {
            let wallet = wallets[index]
            
            guard wallet.isMnemonic else {
                privateKeyAccountCellModels.append(.privateKeyAccount(walletIndex: index))
                continue
            }
            
            let accounts = wallet.accounts
            let cellModels = (0..<accounts.count).map { CellModel.mnemonicAccount(walletIndex: index, accountIndex: $0) }
            sections.append(.mnemonicWallet(cellModels: cellModels))
        }
        
        if !privateKeyAccountCellModels.isEmpty {
            sections.append(.privateKeyWallets(cellModels: privateKeyAccountCellModels))
        }
    }
    
    @objc private func processInput() {
        let prefix = "tokenary://"
        guard let url = launchURL?.absoluteString, url.hasPrefix(prefix),
              let request = SafariRequest(query: String(url.dropFirst(prefix.count))) else { return }
        launchURL = nil
        
        let action = DappRequestProcessor.processSafariRequest(request) { [weak self] in
            self?.openSafari(requestId: request.id)
        }
        
        switch action {
        case .none, .justShowApp:
            break
        case .selectAccount(let action), .switchAccount(let action):
            let selectAccountViewController = instantiate(AccountsListViewController.self, from: .main)
            selectAccountViewController.onSelectedWallet = action.completion
            presentForSafariRequest(selectAccountViewController.inNavigationController, id: request.id)
        case .approveMessage(let action):
            let approveViewController = ApproveViewController.with(subject: action.subject,
                                                                   provider: action.provider,
                                                                   account: action.account,
                                                                   meta: action.meta,
                                                                   peerMeta: action.peerMeta,
                                                                   completion: action.completion)
            presentForSafariRequest(approveViewController.inNavigationController, id: request.id)
        case .approveTransaction(let action):
            let approveTransactionViewController = ApproveTransactionViewController.with(transaction: action.transaction,
                                                                                         chain: action.chain,
                                                                                         account: action.account,
                                                                                         peerMeta: action.peerMeta,
                                                                                         completion: action.completion)
            presentForSafariRequest(approveTransactionViewController.inNavigationController, id: request.id)
        }
    }
    
    private func presentForSafariRequest(_ viewController: UIViewController, id: Int) {
        var presentFrom: UIViewController = self
        while let presented = presentFrom.presentedViewController, !(presented is UIAlertController) {
            presentFrom = presented
        }
        if let alert = presentFrom.presentedViewController as? UIAlertController {
            alert.dismiss(animated: false)
        }
        presentFrom.present(viewController, animated: true)
        toDismissAfterResponse[id] = viewController
    }
    
    private func openSafari(requestId: Int) {
        UIApplication.shared.openSafari()
        toDismissAfterResponse[requestId]?.dismiss(animated: false)
        toDismissAfterResponse.removeValue(forKey: requestId)
    }
    
    @IBAction func selectNetworkButtonTapped(_ sender: Any) {
        let actionSheet = UIAlertController(title: Strings.selectNetwork, message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.sourceView = selectNetworkButton
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
        actionSheet.popoverPresentationController?.sourceView = selectNetworkButton
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
        selectNetworkButton.configuration?.title = chain.name
        self.chain = chain
        if selectNetworkButton.configuration?.image == nil {
            selectNetworkButton.configuration?.imagePadding = 4
            selectNetworkButton.configuration?.imagePlacement = .trailing
            selectNetworkButton.configuration?.image = Images.chevronDown
        }
    }
    
    @objc private func cancelButtonTapped() {
        onSelectedWallet?(nil, nil, nil)
    }
    
    @objc private func walletsChanged() {
        reloadData()
    }
    
    private func updateDataState() {
        let isEmpty = sections.isEmpty
        dataState = isEmpty ? .noData : .hasData
        let canScroll = !isEmpty
        if tableView.isScrollEnabled != canScroll {
            tableView.isScrollEnabled = canScroll
        }
    }
    
    private func reloadData() {
        updateCellModels()
        updateDataState()
        tableView.reloadData()
    }
    
    @objc private func preferencesButtonTapped() {
        let actionSheet = UIAlertController(title: "❤️ " + Strings.tokenary + " ❤️", message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.barButtonItem = preferencesItem
        let twitterAction = UIAlertAction(title: Strings.viewOnTwitter, style: .default) { _ in
            UIApplication.shared.open(URL.twitter)
        }
        let githubAction = UIAlertAction(title: Strings.viewOnGithub, style: .default) { _ in
            UIApplication.shared.open(URL.github)
        }
        let emailAction = UIAlertAction(title: Strings.dropUsALine.withEllipsis, style: .default) { _ in
            UIApplication.shared.open(URL.email)
        }
        let shareInvite = UIAlertAction(title: Strings.shareInvite.withEllipsis, style: .default) { [weak self] _ in
            let shareViewController = UIActivityViewController(activityItems: [URL.appStore], applicationActivities: nil)
            shareViewController.popoverPresentationController?.barButtonItem = self?.preferencesItem
            shareViewController.excludedActivityTypes = [.addToReadingList, .airDrop, .assignToContact, .openInIBooks, .postToFlickr, .postToVimeo, .markupAsPDF]
            self?.present(shareViewController, animated: true)
        }
        let howToEnableSafariExtension = UIAlertAction(title: Strings.howToEnableSafariExtension, style: .default) { _ in
            UIApplication.shared.open(URL.iosSafariGuide)
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        actionSheet.addAction(twitterAction)
        actionSheet.addAction(githubAction)
        actionSheet.addAction(emailAction)
        actionSheet.addAction(shareInvite)
        actionSheet.addAction(howToEnableSafariExtension)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    @objc private func addWallet() {
        let actionSheet = UIAlertController(title: Strings.addWallet, message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.barButtonItem = addWalletItem
        let newAccountAction = UIAlertAction(title: "🌱 " + Strings.createNew, style: .default) { [weak self] _ in
            self?.createNewWallet()
        }
        let importAccountAction = UIAlertAction(title: Strings.importExisting, style: .default) { [weak self] _ in
            self?.importExistingWallet()
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        actionSheet.addAction(newAccountAction)
        actionSheet.addAction(importAccountAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    private func createNewWallet() {
        let alert = UIAlertController(title: Strings.backUpNewWallet, message: Strings.youWillSeeSecretWords, preferredStyle: .alert)
        let okAction = UIAlertAction(title: Strings.ok, style: .default) { [weak self] _ in
            self?.createNewWalletAndShowSecretWords()
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        alert.addAction(cancelAction)
        alert.addAction(okAction)
        present(alert, animated: true)
    }
    
    private func createNewWalletAndShowSecretWords() {
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
    
    private func importExistingWallet() {
        let importViewController = instantiate(ImportViewController.self, from: .main)
        present(importViewController.inNavigationController, animated: true)
    }
    
    private func showActionsForWallet(wallet: TokenaryWallet, headerView: AccountsHeaderView) {
        let actionSheet = UIAlertController(title: Strings.multicoinWallet, message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.sourceView = headerView
        
        let editAction = UIAlertAction(title: Strings.editAccounts, style: .default) { [weak self] _ in
            let editAccountsViewController = instantiate(EditAccountsViewController.self, from: .main)
            editAccountsViewController.wallet = wallet
            self?.present(editAccountsViewController.inNavigationController, animated: true)
        }
        
        let showKeyAction = UIAlertAction(title: Strings.showSecretWords, style: .default) { [weak self] _ in
            self?.didTapExportWallet(wallet)
        }
        
        let removeAction = UIAlertAction(title: Strings.removeWallet, style: .destructive) { [weak self] _ in
            self?.askBeforeRemoving(wallet: wallet)
        }
        
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        
        actionSheet.addAction(editAction)
        actionSheet.addAction(showKeyAction)
        actionSheet.addAction(removeAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    private func showActionsForAccount(_ account: Account, wallet: TokenaryWallet, cell: UITableViewCell?) {
        let actionSheet = UIAlertController(title: account.coin.name, message: account.address, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.sourceView = cell
        
        let copyAddressAction = UIAlertAction(title: Strings.copyAddress, style: .default) { _ in
            UIPasteboard.general.string = account.address
        }
        
        let explorerAction = UIAlertAction(title: account.coin.viewOnExplorerTitle, style: .default) { _ in
            UIApplication.shared.open(account.coin.explorerURL(address: account.address))
        }
        
        let showKeyTitle = wallet.isMnemonic ? Strings.showSecretWords : Strings.showPrivateKey
        let showKeyAction = UIAlertAction(title: showKeyTitle, style: .default) { [weak self] _ in
            self?.didTapExportWallet(wallet)
        }
        
        let removeTitle = wallet.isMnemonic ? Strings.removeAccount : Strings.removeWallet
        let removeAction = UIAlertAction(title: removeTitle, style: .destructive) { [weak self] _ in
            if wallet.isMnemonic {
                self?.attemptToRemoveAccount(account, fromWallet: wallet)
            } else {
                self?.askBeforeRemoving(wallet: wallet)
            }
        }
        
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        
        actionSheet.addAction(copyAddressAction)
        actionSheet.addAction(explorerAction)
        actionSheet.addAction(showKeyAction)
        actionSheet.addAction(removeAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    private func attemptToRemoveAccount(_ account: Account, fromWallet wallet: TokenaryWallet) {
        guard wallet.accounts.count > 1 else {
            warnOnLastAccountRemovalAttempt(wallet: wallet)
            return
        }
        
        do {
            try walletsManager.update(wallet: wallet, removeAccounts: [account])
        } catch {
            showMessageAlert(text: Strings.somethingWentWrong)
        }
    }
    
    private func warnOnLastAccountRemovalAttempt(wallet: TokenaryWallet) {
        let alert = UIAlertController(title: Strings.removingTheLastAccount, message: nil, preferredStyle: .alert)
        
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        let removeAction = UIAlertAction(title: Strings.removeAnyway, style: .destructive) { [weak self] _ in
            self?.askBeforeRemoving(wallet: wallet)
        }
        
        alert.addAction(cancelAction)
        alert.addAction(removeAction)
        
        present(alert, animated: true)
    }
    
    private func askBeforeRemoving(wallet: TokenaryWallet) {
        let alert = UIAlertController(title: Strings.removedWalletsCantBeRecovered, message: nil, preferredStyle: .alert)
        let removeAction = UIAlertAction(title: Strings.removeAnyway, style: .destructive) { [weak self] _ in
            LocalAuthentication.attempt(reason: Strings.removeWallet, presentPasswordAlertFrom: self, passwordReason: Strings.toRemoveWallet) { success in
                if success {
                    self?.removeWallet(wallet)
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
    
    private func didTapExportWallet(_ wallet: TokenaryWallet) {
        let isMnemonic = wallet.isMnemonic
        let title = isMnemonic ? Strings.secretWordsGiveFullAccess : Strings.privateKeyGivesFullAccess
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        let okAction = UIAlertAction(title: Strings.iUnderstandTheRisks, style: .default) { [weak self] _ in
            let reason = isMnemonic ? Strings.showSecretWords : Strings.showPrivateKey
            let passwordReason = isMnemonic ? Strings.toShowSecretWords : Strings.toShowPrivateKey
            LocalAuthentication.attempt(reason: reason, presentPasswordAlertFrom: self, passwordReason: passwordReason) { success in
                if success {
                    self?.showKey(wallet: wallet, mnemonic: isMnemonic)
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
        guard editingStyle == .delete else { return }
        let wallet = walletForIndexPath(indexPath)
        let account = accountForIndexPath(indexPath)
        
        if wallet.isMnemonic {
            attemptToRemoveAccount(account, fromWallet: wallet)
        } else {
            askBeforeRemoving(wallet: wallet)
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let wallet = walletForIndexPath(indexPath)
        let account = accountForIndexPath(indexPath)
        if forWalletSelection {
            onSelectedWallet?(chain, wallet, account)
        } else {
            showActionsForAccount(account, wallet: wallet, cell: tableView.cellForRow(at: indexPath))
        }
    }
    
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 15
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 37
    }
    
}

extension AccountsListViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].items.count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellOfType(AccountTableViewCell.self, for: indexPath)
        let account = accountForIndexPath(indexPath)
        cell.setup(title: account.croppedAddress, image: account.image, delegate: self)
        return cell
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let item = sections[section]
        let title: String
        let showsButton: Bool
        switch item {
        case .privateKeyWallets:
            title = Strings.privateKeyWallets
            showsButton = false
        case .mnemonicWallet:
            title = Strings.multicoinWallet
            showsButton = true
        }
        
        let headerView = tableView.dequeueReusableHeaderFooterOfType(AccountsHeaderView.self)
        headerView.set(title: title, showsButton: showsButton, sectionIndex: section, delegate: self)
        return headerView
    }
    
}

extension AccountsListViewController: AccountsHeaderViewDelegate {
    
    func didTapEditButton(_ sender: AccountsHeaderView, sectionIndex: Int) {
        let wallet = walletForIndexPath(IndexPath(row: 0, section: sectionIndex))
        showActionsForWallet(wallet: wallet, headerView: sender)
    }
    
}

extension AccountsListViewController: AccountTableViewCellDelegate {
    
    func didTapMoreButton(accountCell: AccountTableViewCell) {
        guard let indexPath = tableView.indexPath(for: accountCell) else { return }
        showActionsForAccount(accountForIndexPath(indexPath), wallet: walletForIndexPath(indexPath), cell: accountCell)
    }
    
}
