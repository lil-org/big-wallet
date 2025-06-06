// ∅ 2025 lil org

import UIKit
import SwiftUI
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
    
    private var wallets: [WalletContainer] {
        return walletsManager.wallets
    }
    
    private var forWalletSelection: Bool {
        return selectAccountAction != nil
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
    
    override var prefersHomeIndicatorAutoHidden: Bool {
        return screenshotMode ? true : super.prefersHomeIndicatorAutoHidden
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        primaryButton.setTitle(Strings.connect, for: .normal)
        secondaryButton.setTitle(Strings.cancel, for: .normal)
        
        if walletsManager.wallets.isEmpty {
            walletsManager.start()
        }
        
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
        let cancelItem = UIBarButtonItem(title: Strings.cancel, style: .plain, target: self, action: #selector(cancelButtonTapped))
        self.addWalletItem = addItem
        self.preferencesItem = preferencesItem
        navigationItem.rightBarButtonItems = forWalletSelection ? [addItem] : [addItem, preferencesItem]
        if forWalletSelection {
            navigationItem.leftBarButtonItem = cancelItem
        }
        configureDataState(.noData, description: Strings.nothingHere, buttonTitle: Strings.addWallet) { [weak self] in
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
    
    private func walletForIndexPath(_ indexPath: IndexPath) -> WalletContainer {
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
        
        guard let inputLinkString = inputLinkString else { return }
        
        let action: DappRequestAction
        let id: Int
        if let prefix = ["https://lil.org/extension?query=", "bigwallet://safari?request="].first(where: { inputLinkString.hasPrefix($0) == true }),
           let request = SafariRequest(query: String(inputLinkString.dropFirst(prefix.count))) {
            id = request.id
            action = DappRequestProcessor.processSafariRequest(request) { [weak self] hash in
                self?.redirectBack(requestId: id)
            }
        } else {
            return
        }
        
        switch action {
        case .none, .justShowApp:
            break
        case .selectAccount(let action), .switchAccount(let action):
            let selectAccountViewController = instantiate(AccountsListViewController.self, from: .main)
            selectAccountViewController.selectAccountAction = action
            presentForExternalRequest(selectAccountViewController.inNavigationController, id: id)
        case .approveMessage(let action):
            let approveViewController = ApproveViewController.with(subject: action.subject,
                                                                   provider: action.provider,
                                                                   account: action.account,
                                                                   walletId: action.walletId,
                                                                   meta: action.meta,
                                                                   peerMeta: action.peerMeta,
                                                                   completion: action.completion)
            presentForExternalRequest(approveViewController.inNavigationController, id: id)
        case .approveTransaction(let action):
            let approveTransactionViewController = ApproveTransactionViewController.with(transaction: action.transaction,
                                                                                         chain: action.chain,
                                                                                         account: action.account,
                                                                                         walletId: action.walletId,
                                                                                         peerMeta: action.peerMeta,
                                                                                         completion: action.completion)
            presentForExternalRequest(approveTransactionViewController.inNavigationController, id: id)
        case .addEthereumChain(let action):
            let message = action.chainToAdd.chainName + "\n\n" + action.chainToAdd.defaultRpcUrl
            let alert = UIAlertController(title: Strings.addNetwork, message: message, preferredStyle: .alert)
            let okAction = UIAlertAction(title: Strings.ok, style: .default) { _ in
                action.completion(true)
            }
            let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel) { _ in
                action.completion(false)
            }
            alert.addAction(cancelAction)
            alert.addAction(okAction)
            presentForExternalRequest(alert, id: id)
        case let .showMessage(message, subtitle, completion):
            let alert = UIAlertController(title: message, message: subtitle, preferredStyle: .alert)
            let okAction = UIAlertAction(title: Strings.ok, style: .default) { _ in
                completion?()
            }
            alert.addAction(okAction)
            presentForExternalRequest(alert, id: id)
        }
    }
    
    private func presentForExternalRequest(_ viewController: UIViewController, id: Int) {
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
    
    private func redirectBack(requestId: Int) {
        UIApplication.shared.openSafari()
        closePopups(requestId: requestId)
    }
    
    private func closePopups(requestId: Int) {
#if os(iOS)
        let isFullscreen = view.bounds.width == UIScreen.main.bounds.width
#else
        let isFullscreen = false
#endif
        toDismissAfterResponse[requestId]?.dismiss(animated: !isFullscreen)
        toDismissAfterResponse.removeValue(forKey: requestId)
    }
    
    @IBAction func networkButtonTapped(_ sender: Any) {
        guard selectAccountAction?.coinType == nil || selectAccountAction?.coinType == .ethereum else {
            showMessageAlert(text: selectAccountAction?.coinType?.name ?? Strings.unknownNetwork)
            return
        }
        
        showNetworksList()
    }
    
    private func showNetworksList() {
        let networksList = NetworksListView(selectedNetwork: network) { [weak self] newSelected in
            guard let newSelected = newSelected else { return }
            self?.selectNetwork(newSelected)
        }
        
        let hostingController = UIHostingController(rootView: networksList)
        present(hostingController, animated: true)
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
        let actionSheet = UIAlertController(title: Strings.bigWallet, message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.barButtonItem = preferencesItem
        
        let appStoreAction = UIAlertAction(title: Strings.rateOnTheAppStore, style: .default) { _ in
            ReviewRequster.didClickAppStoreReviewButton()
        }
        
        let xAction = UIAlertAction(title: Strings.viewOnX, style: .default) { _ in
            UIApplication.shared.open(URL.x)
        }
        let farcasterAction = UIAlertAction(title: Strings.viewOnFarcaster, style: .default) { _ in
            UIApplication.shared.open(URL.farcaster)
        }
        let githubAction = UIAlertAction(title: Strings.viewOnGithub, style: .default) { _ in
            UIApplication.shared.open(URL.github)
        }
        let emailAction = UIAlertAction(title: Strings.dropUsALine, style: .default) { _ in
            UIApplication.shared.open(URL.email)
        }
        let howToEnableSafariExtension = UIAlertAction(title: Strings.enableSafariExtension, style: .default) { _ in
            UIApplication.shared.open(URL.iosSafariGuide)
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        actionSheet.addAction(howToEnableSafariExtension)
        actionSheet.addAction(appStoreAction)
        
        actionSheet.addAction(farcasterAction)
        actionSheet.addAction(githubAction)
        actionSheet.addAction(emailAction)
        actionSheet.addAction(xAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    @objc private func addWallet() {
        let actionSheet = UIAlertController(title: Strings.addWallet, message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.barButtonItem = addWalletItem
        let newAccountAction = UIAlertAction(title: Strings.createNew, style: .default) { [weak self] _ in
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
        showKey(wallet: wallet, specificAccount: nil)
    }
    
    private func showKey(wallet: WalletContainer, specificAccount: Account?) {
        let secret: String
        let showingMnemonic = wallet.isMnemonic && specificAccount == nil
        
        if let account = specificAccount, wallet.isMnemonic {
            if let hex = walletsManager.getPrivateKey(wallet: wallet, account: account)?.data.hexString {
                secret = hex
            } else {
                return
            }
        } else if wallet.isMnemonic, let mnemonicString = try? walletsManager.exportMnemonic(wallet: wallet) {
            secret = mnemonicString
        } else if let data = try? walletsManager.exportPrivateKey(wallet: wallet) {
            secret = data.hexString
        } else {
            return
        }
        
        let alert = UIAlertController(title: showingMnemonic ? Strings.secretWords : Strings.privateKey, message: secret, preferredStyle: .alert)
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
    
    private func showActionsForWallet(wallet: WalletContainer, headerView: AccountsHeaderView) {
        let currentName = WalletsMetadataService.getWalletName(wallet: wallet)
        
        let actionSheet = UIAlertController(title: currentName ?? Strings.multicoinWallet, message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.sourceView = headerView
        
        let editAction = UIAlertAction(title: Strings.editAccounts, style: .default) { [weak self] _ in
            let editAccountsViewController = instantiate(EditAccountsViewController.self, from: .main)
            editAccountsViewController.wallet = wallet
            self?.present(editAccountsViewController.inNavigationController, animated: true)
        }
        
        let nameActionTitle = currentName == nil ? Strings.setName : Strings.editName
        let nameAction = UIAlertAction(title: nameActionTitle, style: .default) { [weak self] _ in
            self?.didSelectNameActionForWallet(wallet)
        }
        
        let showKeyAction = UIAlertAction(title: Strings.showSecretWords, style: .default) { [weak self] _ in
            self?.didTapExportWallet(wallet, specificAccount: nil)
        }
        
        let removeAction = UIAlertAction(title: Strings.removeWallet, style: .destructive) { [weak self] _ in
            self?.askBeforeRemoving(wallet: wallet)
        }
        
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        
        actionSheet.addAction(editAction)
        actionSheet.addAction(nameAction)
        actionSheet.addAction(showKeyAction)
        actionSheet.addAction(removeAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    private func didSelectNameActionForWallet(_ wallet: WalletContainer) {
        let initialText = WalletsMetadataService.getWalletName(wallet: wallet)
        showTextInputAlert(title: initialText == nil ? Strings.setName : Strings.editName, message: nil, initialText: initialText, placeholder: Strings.multicoinWallet) { [weak self] newName in
            if let newName = newName {
                WalletsMetadataService.saveWalletName(newName, wallet: wallet)
                self?.tableView.reloadData()
            }
        }
    }
    
    private func didSelectNameActionForAccount(_ account: Account, wallet: WalletContainer) {
        let initialText = account.name(walletId: wallet.id)
        let nameActionTitle = initialText == nil ? Strings.setName : Strings.editName
        showTextInputAlert(title: nameActionTitle, message: nil, initialText: initialText, placeholder: account.croppedAddress) { [weak self] newName in
            if let newName = newName {
                WalletsMetadataService.saveAccountName(newName, wallet: wallet, account: account)
                self?.tableView.reloadData()
            }
        }
    }
    
    private func showActionsForAccount(_ account: Account, wallet: WalletContainer, cell: UITableViewCell?) {
        let actionSheet = UIAlertController(title: account.coin.name, message: account.address, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.sourceView = cell
        
        let copyAddressAction = UIAlertAction(title: Strings.copyAddress, style: .default) { _ in
            UIPasteboard.general.string = account.address
        }
        let showKeyTitle = wallet.isMnemonic ? Strings.showSecretWords : Strings.showPrivateKey
        let showKeyAction = UIAlertAction(title: showKeyTitle, style: .default) { [weak self] _ in
            self?.didTapExportWallet(wallet, specificAccount: nil)
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
        
        for (name, url) in account.coin.explorersFor(address: account.address) {
            let explorerAction = UIAlertAction(title: name, style: .default) { _ in
                UIApplication.shared.open(url)
            }
            actionSheet.addAction(explorerAction)
        }
        
        actionSheet.addAction(copyAddressAction)
        
        let currentName = account.name(walletId: wallet.id)
        let nameActionTitle = currentName == nil ? Strings.setName : Strings.editName
        let nameAction = UIAlertAction(title: nameActionTitle, style: .default) { [weak self] _ in
            self?.didSelectNameActionForAccount(account, wallet: wallet)
        }
        actionSheet.addAction(nameAction)
        
        actionSheet.addAction(showKeyAction)
        
        if wallet.isMnemonic {
            let showPrivateKeyAction = UIAlertAction(title: Strings.showPrivateKey, style: .default) { [weak self] _ in
                self?.didTapExportWallet(wallet, specificAccount: account)
            }
            actionSheet.addAction(showPrivateKeyAction)
        }
        
        actionSheet.addAction(removeAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    private func attemptToRemoveAccount(_ account: Account, fromWallet wallet: WalletContainer) {
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
    
    private func warnOnLastAccountRemovalAttempt(wallet: WalletContainer) {
        let alert = UIAlertController(title: Strings.removingTheLastAccount, message: nil, preferredStyle: .alert)
        
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        let removeAction = UIAlertAction(title: Strings.removeAnyway, style: .destructive) { [weak self] _ in
            self?.askBeforeRemoving(wallet: wallet)
        }
        
        alert.addAction(cancelAction)
        alert.addAction(removeAction)
        
        present(alert, animated: true)
    }
    
    private func askBeforeRemoving(wallet: WalletContainer) {
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
    
    private func removeWallet(_ wallet: WalletContainer) {
        try? walletsManager.delete(wallet: wallet)
        reloadData()
    }
    
    private func didTapExportWallet(_ wallet: WalletContainer, specificAccount: Account?) {
        let willExportMnemonic = wallet.isMnemonic && specificAccount == nil
        let title = willExportMnemonic ? Strings.secretWordsGiveFullAccess : Strings.privateKeyGivesFullAccess
        let alert = UIAlertController(title: title, message: specificAccount?.nameOrCroppedAddress(walletId: wallet.id), preferredStyle: .alert)
        let okAction = UIAlertAction(title: Strings.iUnderstandTheRisks, style: .default) { [weak self] _ in
            let reason = willExportMnemonic ? Strings.showSecretWords : Strings.showPrivateKey
            let passwordReason = willExportMnemonic ? Strings.toShowSecretWords : Strings.toShowPrivateKey
            LocalAuthentication.attempt(reason: reason, presentPasswordAlertFrom: self, passwordReason: passwordReason) { success in
                if success {
                    self?.showKey(wallet: wallet, specificAccount: specificAccount)
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
        cell.setup(title: account.nameOrCroppedAddress(walletId: wallet.id),
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
        case .mnemonicWallet(_, let index):
            let wallet = wallets[index]
            let name = WalletsMetadataService.getWalletName(wallet: wallet)
            title = name ?? Strings.multicoinWallet
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
