// Copyright © 2021 Tokenary. All rights reserved.

import UIKit
import WalletCore

class AccountsListViewController: UIViewController, DataStateContainer {
    
    enum Section {
        case privateKeyWallets(cellModels: [CellModel])
        case mnemonicWallet(cellModels: [CellModel], walletIndex: Int)
        
        var items: [CellModel] {
            switch self {
            case let .mnemonicWallet(cellModels: cellModels, _):
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
    
    private var network = Networks.ethereum
    var selectAccountAction: SelectAccountAction?
    
    private var wallets: [TokenaryWallet] {
        return walletsManager.wallets
    }
    
    private var didAppear = false
    private var toDismissAfterResponse = [Int: UIViewController]()
    private var preferencesItem: UIBarButtonItem?
    private var addWalletItem: UIBarButtonItem?
    private var initialContentOffset: CGFloat?
    
    @IBOutlet weak var bottomOverlayView: UIVisualEffectView!
    @IBOutlet weak var websiteLogoImageView: UIImageView!
    @IBOutlet weak var websiteNameLabel: UILabel!
    @IBOutlet weak var topOverlayView: UIView!
    @IBOutlet weak var topOverlayTopConstraint: NSLayoutConstraint!
    @IBOutlet weak var networkButton: UIButton!
    @IBOutlet weak var secondaryButton: UIButton!
    @IBOutlet weak var primaryButton: UIButton!
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
        
        let forWalletSelection = selectAccountAction != nil
        if forWalletSelection {
            if selectAccountAction?.initiallyConnectedProviders.isEmpty ?? true {
                navigationItem.title = Strings.selectAccount
            } else {
                navigationItem.title = Strings.switchAccount
            }
        } else {
            navigationItem.title = Strings.wallets
        }
        
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
        NotificationCenter.default.addObserver(self, selector: #selector(processInput), name: .receievedWalletRequest, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil)
        
        bottomOverlayView.isHidden = !forWalletSelection
        topOverlayView.isHidden = !forWalletSelection
        if let selectAccountAction = selectAccountAction {
            let bottomOverlayHeight: CGFloat = 70
            tableView.contentInset.bottom += bottomOverlayHeight
            tableView.contentInset.top += 70
            tableView.verticalScrollIndicatorInsets.bottom += bottomOverlayHeight
            if !selectAccountAction.initiallyConnectedProviders.isEmpty {
                primaryButton.setTitle(Strings.ok, for: .normal)
                secondaryButton.setTitle(Strings.disconnect, for: .normal)
                secondaryButton.tintColor = .systemRed
            }
            updatePrimaryButton()
            
            if let network = selectAccountAction.network, self.network != network {
                selectNetwork(network)
            }
            
            if let peer = selectAccountAction.peer {
                websiteNameLabel.text = peer.name
                if let urlString = peer.iconURLString, let url = URL(string: urlString) {
                    websiteLogoImageView.kf.setImage(with: url)
                }
            } else {
                websiteNameLabel.text = Strings.unknownWebsite
            }
            
            if let name = selectAccountAction.coinType?.name, selectAccountAction.selectedAccounts.isEmpty, !wallets.isEmpty {
                showMessageAlert(text: String(format: Strings.addAccountToConnect, arguments: [name]))
            }
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        processInput()
        requestAnUpdateIfNeeded()
        didAppear = true
        DispatchQueue.main.async { [weak self] in
            let heightBefore = self?.navigationController?.navigationBar.frame.height ?? 0
            self?.navigationController?.navigationBar.sizeToFit()
            let heightAfter = self?.navigationController?.navigationBar.frame.height ?? 0
            if self?.initialContentOffset == nil && self?.sections.isEmpty == false {
                self?.initialContentOffset = (self?.tableView.contentOffset.y ?? 0) + heightBefore - heightAfter
                if let selectedAccounts = self?.selectAccountAction?.selectedAccounts {
                    self?.scrollToTheFirst(selectedAccounts)
                }
            }
        }
    }
    
    private func requestAnUpdateIfNeeded() {
        let configurationService = ConfigurationService.shared
        guard !didAppear, configurationService.shouldPromptToUpdate else { return }
        configurationService.didPromptToUpdate()
        let alert = UIAlertController(title: Strings.thisAppVersionIsNoLongerSupported, message: Strings.pleaseGetANewOne, preferredStyle: .alert)
        let notNowAction = UIAlertAction(title: Strings.notNow, style: .destructive)
        let okAction = UIAlertAction(title: Strings.ok, style: .default) { _ in
            UIApplication.shared.open(URL.updateApp)
        }
        alert.addAction(notNowAction)
        alert.addAction(okAction)
        present(alert, animated: true)
    }
    
    private func scrollToTheFirst(_ specificWalletAccounts: Set<SpecificWalletAccount>) {
        for (sectionIndex, section) in sections.enumerated() {
            for (row, cellModel) in section.items.enumerated() {
                let account: SpecificWalletAccount
                switch cellModel {
                case let .mnemonicAccount(walletIndex, accountIndex):
                    account = SpecificWalletAccount(walletId: wallets[walletIndex].id, account: wallets[walletIndex].accounts[accountIndex])
                case let .privateKeyAccount(walletIndex):
                    account = SpecificWalletAccount(walletId: wallets[walletIndex].id, account: wallets[walletIndex].accounts[0])
                }
                if specificWalletAccounts.contains(account) {
                    let indexPath = IndexPath(row: row, section: sectionIndex)
                    tableView.scrollToRow(at: indexPath, at: .none, animated: false)
                    return
                }
            }
        }
    }
    
    private func walletForIndexPath(_ indexPath: IndexPath) -> TokenaryWallet {
        let section = sections[indexPath.section]
        let items = section.items
        
        guard !items.isEmpty else {
            if case let .mnemonicWallet(_, walletIndex) = section {
                return wallets[walletIndex]
            } else {
                fatalError("no wallet")
            }
        }
        
        let item = items[indexPath.row]
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
    
    private func updatePrimaryButton() {
        primaryButton.isEnabled = selectAccountAction?.selectedAccounts.isEmpty == false
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
            sections.append(.mnemonicWallet(cellModels: cellModels, walletIndex: index))
        }
        
        if !privateKeyAccountCellModels.isEmpty {
            sections.append(.privateKeyWallets(cellModels: privateKeyAccountCellModels))
        }
    }
    
    @objc private func processInput() {
        let inputLinkString = launchURL?.absoluteString
        launchURL = nil
        
        guard let inputLinkString = inputLinkString,
              let prefix = ["https://tokenary.io/extension?query=", "tokenary://"].first(where: { inputLinkString.hasPrefix($0) == true }),
              let request = SafariRequest(query: String(inputLinkString.dropFirst(prefix.count))) else { return }
        
        let action = DappRequestProcessor.processSafariRequest(request) { [weak self] in
            self?.openSafari(requestId: request.id)
        }
        
        switch action {
        case .none, .justShowApp:
            break
        case .selectAccount(let action), .switchAccount(let action):
            let selectAccountViewController = instantiate(AccountsListViewController.self, from: .main)
            selectAccountViewController.selectAccountAction = action
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
        let isFullscreen = view.bounds.width == UIScreen.main.bounds.width
        toDismissAfterResponse[requestId]?.dismiss(animated: !isFullscreen)
        toDismissAfterResponse.removeValue(forKey: requestId)
    }
    
    @IBAction func networkButtonTapped(_ sender: Any) {
        guard selectAccountAction?.coinType == nil || selectAccountAction?.coinType == .ethereum else {
            showMessageAlert(text: selectAccountAction?.coinType?.name ?? Strings.unknownNetwork)
            return
        }
        
        let actionSheet = UIAlertController(title: Strings.selectNetwork, message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.sourceView = networkButton
        for network in Networks.allMainnets {
            let prefix = network == self.network ? "✅ " : ""
            let action = UIAlertAction(title: prefix + network.name, style: .default) { [weak self] _ in
                self?.selectNetwork(network)
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
        actionSheet.popoverPresentationController?.sourceView = networkButton
        for network in Networks.allTestnets {
            let prefix = network == self.network ? "✅ " : ""
            let action = UIAlertAction(title: prefix + network.name, style: .default) { [weak self] _ in
                self?.selectNetwork(network)
            }
            actionSheet.addAction(action)
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    private func selectNetwork(_ network: EthereumNetwork) {
        self.network = network
        var tintedConfiguration = UIButton.Configuration.tinted()
        tintedConfiguration.image = networkButton.configuration?.image
        networkButton.configuration = tintedConfiguration
    }
    
    @IBAction func secondaryButtonTapped(_ sender: Any) {
        if selectAccountAction?.initiallyConnectedProviders.isEmpty == false {
            selectAccountAction?.completion(network, [])
        } else {
            selectAccountAction?.completion(network, nil)
        }
    }
    
    @IBAction func primaryButtonTapped(_ sender: Any) {
        selectAccountAction?.completion(network, selectAccountAction?.selectedAccounts.map { $0 })
    }
    
    @objc private func cancelButtonTapped() {
        selectAccountAction?.completion(network, nil)
    }
    
    @objc private func walletsChanged() {
        validateSelectedAccounts()
        updatePrimaryButton()
        reloadData()
    }
    
    private func validateSelectedAccounts() {
        guard let specificWalletAccounts = selectAccountAction?.selectedAccounts else { return }
        for specificWalletAccount in specificWalletAccounts {
            if let wallet = wallets.first(where: { $0.id == specificWalletAccount.walletId }),
               wallet.accounts.contains(specificWalletAccount.account) {
                continue
            } else {
                selectAccountAction?.selectedAccounts.remove(specificWalletAccount)
            }
        }
    }
    
    private func updateDataState() {
        let isEmpty = sections.isEmpty
        dataState = isEmpty ? .noData : .hasData
        let canScroll = !isEmpty
        if tableView.isScrollEnabled != canScroll {
            tableView.isScrollEnabled = canScroll
        }
        
        if didAppear, !isEmpty, initialContentOffset == nil {
            initialContentOffset = tableView.contentOffset.y
        }
    }
    
    private func reloadData() {
        updateCellModels()
        updateDataState()
        tableView.reloadData()
    }
    
    @objc private func preferencesButtonTapped() {
        let actionSheet = UIAlertController(title: "❤️ " + Strings.tokenary.uppercased() + " ⭐️", message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.barButtonItem = preferencesItem
        let xAction = UIAlertAction(title: Strings.viewOnX, style: .default) { _ in
            UIApplication.shared.open(URL.x)
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
        actionSheet.addAction(xAction)
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
    
    private func didClickAccountInSelectionMode(specificWalletAccount: SpecificWalletAccount) {
        let wasSelected = selectAccountAction?.selectedAccounts.contains(specificWalletAccount) == true
        
        if !wasSelected, let toDeselect = selectAccountAction?.selectedAccounts.first(where: { $0.account.coin == specificWalletAccount.account.coin }) {
            selectAccountAction?.selectedAccounts.remove(toDeselect)
        }
        
        if wasSelected {
            selectAccountAction?.selectedAccounts.remove(specificWalletAccount)
        } else {
            selectAccountAction?.selectedAccounts.insert(specificWalletAccount)
        }
        
        updatePrimaryButton()
        tableView.reloadData()
    }
    
    private func accountCanBeSelected(_ account: Account) -> Bool {
        return selectAccountAction?.coinType == nil || selectAccountAction?.coinType == account.coin
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
        if selectAccountAction != nil {
            if accountCanBeSelected(account) {
                let specificWalletAccount = SpecificWalletAccount(walletId: wallet.id, account: account)
                didClickAccountInSelectionMode(specificWalletAccount: specificWalletAccount)
            }
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
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !topOverlayView.isHidden, let initialContentOffset = initialContentOffset {
            let delta = scrollView.contentOffset.y - initialContentOffset
            if delta < 0 {
                topOverlayTopConstraint.constant = -delta
            } else {
                topOverlayTopConstraint.constant = 0
            }
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].items.count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellOfType(AccountTableViewCell.self, for: indexPath)
        let account = accountForIndexPath(indexPath)
        let wallet = walletForIndexPath(indexPath)
        let specificWalletAccount = SpecificWalletAccount(walletId: wallet.id, account: account)
        let isSelected = selectAccountAction?.selectedAccounts.contains(specificWalletAccount) == true
        cell.setup(title: account.croppedAddress,
                   image: account.image,
                   isDisabled: !accountCanBeSelected(account),
                   customSelectionStyle: selectAccountAction != nil,
                   isSelected: isSelected,
                   delegate: self)
        
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
