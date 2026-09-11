// ∅ 2026 lil org

import Cocoa
import LocalAuthentication
import SafariServices

enum NativeAccountSelectionMode {
    case selectAccount, switchAccount
}

final class NativeAccountSelectionSession {
    let coinType: WalletCoin?
    var selectedAccounts: Set<SpecificWalletAccount>
    let initiallyConnectedProviders: Set<InpageProvider>
    let mode: NativeAccountSelectionMode
    var network: EthereumNetwork?

    private let completion: (
        [SpecificWalletAccount]?,
        EthereumNetwork?
    ) -> Void
    private var didComplete = false

    init(
        action: SelectAccountAction,
        mode: NativeAccountSelectionMode,
        completion: @escaping (
            [SpecificWalletAccount]?,
            EthereumNetwork?
        ) -> Void
    ) {
        coinType = action.coinType
        selectedAccounts = action.selectedAccounts
        initiallyConnectedProviders = action.initiallyConnectedProviders
        self.mode = mode
        network = action.network ?? Networks.ethereum
        self.completion = completion
    }

    var canSelectEthereumNetwork: Bool {
        if let coinType {
            return coinType == .ethereum
        }
        return initiallyConnectedProviders.contains(.ethereum) ||
            selectedAccounts.contains { $0.account.coin == .ethereum }
    }

    func canSubmitSelection() -> Bool {
        guard !selectedAccounts.isEmpty else { return false }
        let needsEthereumNetwork = selectedAccounts.contains {
            $0.account.coin == .ethereum
        }
        return !needsEthereumNetwork || network != nil
    }

    func complete(accounts: [SpecificWalletAccount]?) {
        guard !didComplete else { return }
        didComplete = true
        completion(accounts, network)
    }

    func invalidate() {
        didComplete = true
    }
}

class AccountsListViewController: NSViewController {

    enum HeaderMode: Equatable {
        case wallets
        case selectAccount
        case switchAccount
    }

    private let agent = Agent.shared
    private let walletsManager = WalletsManager.shared
    private var cellModels = [CellModel]()
    private var didAppear = false
    private var preferencesButton: NSButton?
    private var authenticationContext: LAContext?
    private var isNativeApprovalReviewInvalidated = false
    private var isSubmittingAccountSelection = false
    var accountSelection: NativeAccountSelectionSession?
    var newWalletId: String?
    var getBackToRect: CGRect?
    
    enum CellModel {
        case mnemonicWalletHeader(walletIndex: Int)
        case privateKeyWalletsHeader
        case mnemonicAccount(walletIndex: Int, accountIndex: Int)
        case privateKeyAccount(walletIndex: Int, account: WalletAccount)
        case addAccountOption(AddAccountOption)
    }
    
    enum AddAccountOption {
        case createNew, importExisting
        
        var title: String {
            switch self {
            case .createNew:
                return Strings.createNew
            case .importExisting:
                return Strings.importExisting
            }
        }
    }
    
    @IBOutlet weak var addButton: NSButton! {
        didSet {
            let menu = NSMenu()
            addButton.menu = menu
            menu.delegate = self
        }
    }
    
    @IBOutlet weak var secondaryButton: NSButton!
    @IBOutlet weak var primaryButton: NSButton!
    @IBOutlet weak var bottomButtonsStackView: NSStackView!
    @IBOutlet weak var accountsListBottomConstraint: NSLayoutConstraint!
    @IBOutlet weak var titleLabelTopConstraint: NSLayoutConstraint!
    @IBOutlet weak var websiteNameStackView: NSStackView!
    @IBOutlet weak var websiteNameLabel: NSTextField!
    @IBOutlet weak var websiteLogoImageView: NSImageView! {
        didSet {
            websiteLogoImageView.wantsLayer = true
            websiteLogoImageView.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.5).cgColor
            websiteLogoImageView.layer?.cornerRadius = 5
        }
    }
    @IBOutlet weak var networkButton: NSButton! {
        didSet {
            networkButton.image = Images.network.with(pointSize: 14, weight: .regular)
        }
    }
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var tableView: RightClickTableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
            let menu = NSMenu()
            menu.delegate = self
            tableView.menu = menu
            tableView.menuSource = self
        }
    }
    
    private var wallets: [WalletContainer] {
        return walletsManager.wallets
    }

    private var canSelectEthereumNetwork: Bool {
        return accountSelection?.canSelectEthereumNetwork == true
    }

    private var acceptsUserActions: Bool {
        !isNativeApprovalReviewInvalidated &&
            !isSubmittingAccountSelection
    }

    private var shouldShowPreferencesButton: Bool {
        return CurrentApp.isDockApp && accountSelection == nil
    }

    static func headerMode(
        accountSelection: NativeAccountSelectionSession?
    ) -> HeaderMode {
        guard let accountSelection else { return .wallets }
        switch accountSelection.mode {
        case .selectAccount:
            return .selectAccount
        case .switchAccount:
            return .switchAccount
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        primaryButton.title = Strings.connect
        secondaryButton.title = Strings.cancel
        
        validateSelectedAccounts()
        setupPreferencesButtonIfNeeded()
        reloadHeader()
        updateBottomButtons()
        updateCellModels()
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil)
        
        if let preselectedAccount = accountSelection?.selectedAccounts.first {
            scrollTo(specificWalletAccount: preselectedAccount)
        }
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        reloadHeader()
        getBackToRectIfNeeded()
        blinkNewWalletCellIfNeeded()
        view.window?.delegate = self
        
        if !didAppear {
            didAppear = true
            if let coin = accountSelection?.coinType, walletsManager.suggestedAccounts(coin: coin).isEmpty, !wallets.isEmpty {
                presentMessageAlert(
                    String(
                        format: Strings.addAccountToConnect,
                        arguments: [coin.name]
                    ),
                    style: .informational
                )
            }
        }
    }
    
    override func viewWillDisappear() {
        super.viewWillDisappear()
        websiteLogoImageView.cancelRemoteImageLoad()
    }

    private func callCompletion(specificWalletAccounts: [SpecificWalletAccount]?) {
        guard acceptsUserActions, let accountSelection else { return }
        isSubmittingAccountSelection = true
        setAccountSelectionControlsEnabled(false)
        cancelMenuTracking()
        closeAllPopupsIfNeeded()
        accountSelection.complete(accounts: specificWalletAccounts)
    }

    private func setAccountSelectionControlsEnabled(_ isEnabled: Bool) {
        addButton.isEnabled = isEnabled
        preferencesButton?.isEnabled = isEnabled
        networkButton.isEnabled = isEnabled
        primaryButton.isEnabled = isEnabled
        secondaryButton.isEnabled = isEnabled
        tableView.isEnabled = isEnabled
    }
    
    private func updateBottomButtons() {
        if let accountSelection {
            accountsListBottomConstraint.constant = 62
            bottomButtonsStackView.isHidden = false
            
            if !accountSelection.initiallyConnectedProviders.isEmpty {
                primaryButton.title = Strings.ok
                secondaryButton.title = Strings.disconnect
                secondaryButton.keyEquivalent = ""
            }
            
            updateNetworkButtonVisibility()
        } else {
            accountsListBottomConstraint.constant = 0
            bottomButtonsStackView.isHidden = true
            networkButton.isHidden = true
        }
        updatePrimaryButton()
    }
    
    private func updatePrimaryButton() {
        guard let accountSelection else {
            primaryButton.isEnabled = false
            return
        }
        primaryButton.isEnabled = acceptsUserActions &&
            accountSelection.canSubmitSelection()
    }
    
    private func reloadHeader() {
        let headerMode: HeaderMode = wallets.isEmpty
            ? .wallets
            : Self.headerMode(accountSelection: accountSelection)
        switch headerMode {
        case .wallets:
            titleLabel.stringValue = Strings.wallets
        case .selectAccount:
            titleLabel.stringValue = Strings.selectAccount
                .replacingOccurrences(of: " ", with: "\n")
        case .switchAccount:
            titleLabel.stringValue = Strings.switchAccount
                .replacingOccurrences(of: " ", with: "\n")
        }
        
        addButton.isHidden = wallets.isEmpty
        preferencesButton?.isHidden = !shouldShowPreferencesButton
        
        if headerMode != .wallets, let peer = nativeApprovalPeer {
            websiteNameLabel.stringValue = peer.name
            titleLabelTopConstraint.constant = 14
            websiteNameStackView.isHidden = false
            if websiteLogoImageView.image == nil {
                websiteLogoImageView.setRemoteImage(with: peer.iconURLString) { [weak websiteLogoImageView] image in
                    guard image != nil else { return }
                    websiteLogoImageView?.layer?.backgroundColor = NSColor.clear.cgColor
                    websiteLogoImageView?.layer?.cornerRadius = 0
                }
            }
        } else {
            titleLabelTopConstraint.constant = 8
            websiteNameStackView.isHidden = true
            websiteLogoImageView.cancelRemoteImageLoad()
        }
    }

    private func setupPreferencesButtonIfNeeded() {
        guard shouldShowPreferencesButton else { return }

        let button = NSButton(image: Images.preferences.with(pointSize: 18, weight: .regular) ?? Images.preferences,
                              target: self,
                              action: #selector(preferencesButtonTapped(_:)))
        button.bezelStyle = .inline
        button.focusRingType = .none
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = Strings.bigWallet
        button.translatesAutoresizingMaskIntoConstraints = false

        let menu = NSMenu(title: Strings.bigWallet)
        menu.delegate = self
        button.menu = menu

        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            button.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 35),
            button.heightAnchor.constraint(equalToConstant: 34)
        ])
        preferencesButton = button
    }
    
    @IBAction func addButtonTapped(_ sender: NSButton) {
        guard acceptsUserActions else { return }
        let menu = sender.menu
        let createItem = NSMenuItem(title: AddAccountOption.createNew.title, action: #selector(didClickCreateAccount), keyEquivalent: "")
        let importItem = NSMenuItem(title: AddAccountOption.importExisting.title, action: #selector(didClickImportAccount), keyEquivalent: "")
        importItem.target = self
        createItem.target = self
        menu?.addItem(createItem)
        menu?.addItem(.separator())
        menu?.addItem(importItem)
        
        var origin = sender.frame.origin
        origin.x += sender.frame.width
        origin.y += sender.frame.height
        menu?.popUp(positioning: nil, at: origin, in: view)
    }

    @objc private func preferencesButtonTapped(_ sender: NSButton) {
        guard acceptsUserActions,
              shouldShowPreferencesButton,
              let menu = sender.menu else { return }

        menu.addItem(preferencesMenuItem(title: Strings.enableSafariExtension, action: #selector(didClickEnableSafariExtension)))
        menu.addItem(preferencesMenuItem(title: Strings.rateOnTheAppStore, action: #selector(didClickRateOnTheAppStore)))
        menu.addItem(.separator())
        menu.addItem(preferencesMenuItem(title: Strings.viewOnGithub, action: #selector(didClickViewOnGithub)))
        menu.addItem(preferencesMenuItem(title: Strings.dropUsALine, action: #selector(didClickDropUsALine)))
        menu.addItem(preferencesMenuItem(title: Strings.viewOnX, action: #selector(didClickViewOnX)))

        var origin = sender.frame.origin
        origin.y += sender.frame.height
        menu.popUp(positioning: nil, at: origin, in: view)
    }

    private func preferencesMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    
    @IBAction func networkButtonTapped(_ sender: NSButton) {
        guard acceptsUserActions, canSelectEthereumNetwork else { return }
        showNetworksList()
    }
    
    private func showNetworksList() {
        let networksList = NetworksListView(selectedNetwork: accountSelection?.network) { [weak self] selectedNetwork in
            guard let self, acceptsUserActions else { return }
            endAllSheets()
            if let selectedNetwork {
                selectNetwork(selectedNetwork)
            }
        }
        
        let popupWindow = makeHostingWindow(content: networksList, title: Strings.selectNetwork)
        view.window?.beginSheet(popupWindow)
    }
    
    @IBAction func didClickSecondaryButton(_ sender: Any) {
        guard acceptsUserActions else { return }
        if accountSelection?.initiallyConnectedProviders.isEmpty == false {
            callCompletion(specificWalletAccounts: [])
        } else {
            callCompletion(specificWalletAccounts: nil)
        }
    }
    
    @IBAction func didClickPrimaryButton(_ sender: Any) {
        guard acceptsUserActions else { return }
        callCompletion(specificWalletAccounts: accountSelection?.selectedAccounts.map { $0 })
    }
    
    private func selectNetwork(_ network: EthereumNetwork) {
        guard acceptsUserActions else { return }
        accountSelection?.network = network
        updateNetworkButton(network)
        updatePrimaryButton()
    }

    private func updateNetworkButton(_ network: EthereumNetwork) {
        let identity = "\(network.chainIdHexString) · \(network.name)"
        networkButton.image = Images.network.with(
            pointSize: 14,
            weight: .semibold,
            color: .controlAccentColor.withSystemEffect(.pressed)
        )
        networkButton.toolTip = identity
        networkButton.setAccessibilityValue(identity)
    }

    private func updateNetworkButtonVisibility() {
        let isVisible = canSelectEthereumNetwork
        networkButton.isHidden = !isVisible
        if isVisible, let network = accountSelection?.network {
            if !network.isEthMainnet {
                updateNetworkButton(network)
            } else {
                let identity = "\(network.chainIdHexString) · \(network.name)"
                networkButton.toolTip = identity
                networkButton.setAccessibilityValue(identity)
            }
        }
    }
    
    private func closeAllPopupsIfNeeded() {
        endAllSheets()
    }

    @objc private func didClickCreateAccount() {
        guard acceptsUserActions else { return }
        let alert = Alert()
        alert.messageText = Strings.backUpNewWallet
        alert.informativeText = Strings.youWillSeeSecretWords
        alert.alertStyle = .critical
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.cancel)
        presentAlert(alert) { [weak self] response in
            guard let self,
                  !isNativeApprovalReviewInvalidated else { return }
            if response == .alertFirstButtonReturn {
                createNewAccountAndShowSecretWords()
            }
        }
    }
    
    private func createNewAccountAndShowSecretWords() {
        guard acceptsUserActions else { return }
        guard let wallet = try? walletsManager.createWallet() else { return }
        newWalletId = wallet.id
        blinkNewWalletCellIfNeeded()
        showKey(wallet: wallet, specificAccount: nil)
    }
    
    private func getBackToRectIfNeeded() {
        guard let rect = getBackToRect else { return }
        getBackToRect = nil
        tableView.scrollToVisible(rect)
    }
    
    private func blinkNewWalletCellIfNeeded() {
        guard let id = newWalletId else { return }
        newWalletId = nil
        guard let newWalletIndex = wallets.firstIndex(where: { $0.id == id }) else { return }
        
        let blinkIndexes = cellModels.enumerated().compactMap { (index, model) -> Int? in
            if case let .mnemonicAccount(walletIndex, _) = model {
                return walletIndex == newWalletIndex ? index : nil
            } else if case let .privateKeyAccount(walletIndex: walletIndex, account: _) = model {
                return walletIndex == newWalletIndex ? index : nil
            } else {
                return nil
            }
        }
        
        if let last = blinkIndexes.last {
            tableView.scrollRowToVisible(last)
        }
        
        for row in blinkIndexes {
            (tableView.rowView(atRow: row, makeIfNecessary: true) as? AccountCellView)?.blink()
        }
    }
    
    @objc private func didClickImportAccount() {
        guard acceptsUserActions else { return }
        let importViewController = instantiate(ImportViewController.self)
        importViewController.accountSelection = accountSelection
        view.window?.contentViewController = importViewController
        closeAllPopupsIfNeeded()
    }
    
    private func scrollTo(specificWalletAccount: SpecificWalletAccount) {
        guard let specificWalletIndex = wallets.firstIndex(where: { $0.id == specificWalletAccount.walletId }),
              let specificAccountIndex = wallets[specificWalletIndex].accounts.firstIndex(where: { $0 == specificWalletAccount.account })
        else { return }
        
        let row = cellModels.firstIndex { cellModel in
            switch cellModel {
            case let .mnemonicAccount(walletIndex, accountIndex):
                return walletIndex == specificWalletIndex && accountIndex == specificAccountIndex
            case let .privateKeyAccount(walletIndex: walletIndex, account: account):
                return walletIndex == specificWalletIndex && account == specificWalletAccount.account
            default:
                return false
            }
        }
        
        if let row = row {
            tableView.scrollRowToVisible(row)
        }
    }
    
    override func cancelOperation(_ sender: Any?) {
        guard acceptsUserActions else { return }
        if accountSelection?.initiallyConnectedProviders.isEmpty == false {
            callCompletion(specificWalletAccounts: nil)
        }
    }
    
    private func walletForRow(_ row: Int) -> WalletContainer? {
        guard row >= 0 else { return nil }
        let item = cellModels[row]
        switch item {
        case let .privateKeyAccount(walletIndex: walletIndex, account: _):
            return wallets[walletIndex]
        case let .mnemonicAccount(walletIndex: walletIndex, accountIndex: _):
            return wallets[walletIndex]
        case let .mnemonicWalletHeader(walletIndex: walletIndex):
            return wallets[walletIndex]
        default:
            return nil
        }
    }
    
    private func accountForRow(_ row: Int) -> WalletAccount? {
        guard row >= 0 else { return nil }
        let item = cellModels[row]
        switch item {
        case let .privateKeyAccount(walletIndex: _, account: account):
            return account
        case let .mnemonicAccount(walletIndex: walletIndex, accountIndex: accountIndex):
            return wallets[walletIndex].accounts[accountIndex]
        default:
            return nil
        }
    }
    
    @objc private func didClickViewOnExplorer(_ sender: NSMenuItem) {
        guard acceptsUserActions else { return }
        if let url = sender.representedObject as? URL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func didClickEnableSafariExtension() {
        guard acceptsUserActions else { return }
        SFSafariApplication.showPreferencesForExtension(withIdentifier: Identifiers.safariExtensionBundle) { error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL.iosSafariGuide)
            }
        }
    }

    @objc private func didClickRateOnTheAppStore() {
        guard acceptsUserActions else { return }
        ReviewRequster.didClickAppStoreReviewButton()
    }

    @objc private func didClickViewOnGithub() {
        guard acceptsUserActions else { return }
        NSWorkspace.shared.open(URL.github)
    }

    @objc private func didClickDropUsALine() {
        guard acceptsUserActions else { return }
        NSWorkspace.shared.open(URL.email)
    }

    @objc private func didClickViewOnX() {
        guard acceptsUserActions else { return }
        NSWorkspace.shared.open(URL.x)
    }
    
    @objc private func didClickCopyAddress(_ sender: AnyObject) {
        guard acceptsUserActions else { return }
        let row = tableView.deselectedRow
        guard let address = accountForRow(row)?.address else { return }
        NSPasteboard.general.clearAndSetString(address)
    }

    @objc private func didClickRemoveWallet(_ sender: AnyObject) {
        guard acceptsUserActions else { return }
        let row = tableView.deselectedRow
        if let wallet = walletForRow(row) {
            warnBeforeRemoving(wallet: wallet)
        }
    }
    
    @objc private func didClickRemoveAccount(_ sender: AnyObject) {
        guard acceptsUserActions else { return }
        let row = tableView.deselectedRow
        guard let wallet = walletForRow(row), let account = accountForRow(row) else { return }
        
        guard wallet.accounts.count > 1 else {
            warnOnLastAccountRemovalAttempt(wallet: wallet)
            return
        }
        
        do {
            try walletsManager.update(wallet: wallet, removeAccounts: [account])
        } catch {
            presentMessageAlert(Strings.somethingWentWrong, style: .informational)
        }
    }
    
    private func warnOnLastAccountRemovalAttempt(wallet: WalletContainer) {
        let alert = Alert()
        alert.messageText = Strings.removingTheLastAccount
        alert.alertStyle = .critical
        
        alert.addButton(withTitle: Strings.cancel)
        alert.addButton(withTitle: Strings.removeAnyway)
        presentAlert(alert) { [weak self] response in
            guard let self,
                  !isNativeApprovalReviewInvalidated else { return }
            if response != .alertFirstButtonReturn {
                warnBeforeRemoving(wallet: wallet)
            }
        }
    }
    
    private func warnBeforeRemoving(wallet: WalletContainer) {
        let alert = Alert()
        alert.messageText = Strings.removedWalletsCantBeRecovered
        alert.alertStyle = .critical
        alert.addButton(withTitle: Strings.removeAnyway)
        alert.addButton(withTitle: Strings.cancel)
        presentAlert(alert) { [weak self] response in
            guard let self,
                  !isNativeApprovalReviewInvalidated else { return }
            if response == .alertFirstButtonReturn {
                authenticationContext = agent.askAuthentication(
                    on: view.window,
                    getBackTo: self,
                    browser: nil,
                    onStart: false,
                    reason: .removeWallet
                ) { [weak self] allowed in
                    guard let self,
                          !isNativeApprovalReviewInvalidated else { return }
                    authenticationContext = nil
                    Window.activateWindow(view.window)
                    if allowed {
                        removeWallet(wallet)
                    }
                }
            }
        }
    }
    
    private func removeWallet(_ wallet: WalletContainer) {
        try? walletsManager.delete(wallet: wallet)
    }
    
    @objc private func walletsChanged() {
        guard acceptsUserActions else { return }
        validateSelectedAccounts()
        reloadHeader()
        updateBottomButtons()
        updateCellModels()
        tableView.reloadData()
    }
    
    @objc private func didClickShowKey(_ sender: AnyObject) {
        guard acceptsUserActions else { return }
        let row = tableView.deselectedRow
        guard let wallet = walletForRow(row) else { return }
        warnBeforeShowingKey(wallet: wallet, specificAccount: nil)
    }
    
    @objc private func didClickEditAccountName(_ sender: AnyObject) {
        guard acceptsUserActions else { return }
        let row = tableView.deselectedRow
        guard let wallet = walletForRow(row), let account = accountForRow(row) else { return }
        let initialText = account.name(walletId: wallet.id)
        let nameActionTitle = initialText == nil ? Strings.setName : Strings.editName
        presentTextInputAlert(
            title: nameActionTitle,
            initialText: initialText,
            placeholder: account.croppedAddress
        ) { [weak self] newName in
            guard let self,
                  !isNativeApprovalReviewInvalidated else { return }
            if let newName {
                WalletsMetadataService.saveAccountName(newName, wallet: wallet, account: account)
                tableView.reloadData()
            }
        }
    }
    
    @objc private func didClickShowSpecificPrivateKey(_ sender: AnyObject) {
        guard acceptsUserActions else { return }
        let row = tableView.deselectedRow
        guard let wallet = walletForRow(row), let account = accountForRow(row) else { return }
        warnBeforeShowingKey(wallet: wallet, specificAccount: account)
    }
    
    private func warnBeforeShowingKey(wallet: WalletContainer, specificAccount: WalletAccount?) {
        let alert = Alert()
        let showingMnemonic = wallet.isMnemonic && specificAccount == nil
        alert.messageText = showingMnemonic ? Strings.secretWordsGiveFullAccess : Strings.privateKeyGivesFullAccess
        alert.alertStyle = .critical
        alert.addButton(withTitle: Strings.iUnderstandTheRisks)
        alert.addButton(withTitle: Strings.cancel)
        presentAlert(alert) { [weak self] response in
            guard let self,
                  !isNativeApprovalReviewInvalidated else { return }
            if response == .alertFirstButtonReturn {
                let reason: AuthenticationReason = showingMnemonic
                    ? .showSecretWords
                    : .showPrivateKey
                authenticationContext = agent.askAuthentication(
                    on: view.window,
                    getBackTo: self,
                    browser: nil,
                    onStart: false,
                    reason: reason
                ) { [weak self] allowed in
                    guard let self,
                          !isNativeApprovalReviewInvalidated else { return }
                    authenticationContext = nil
                    Window.activateWindow(view.window)
                    if allowed {
                        showKey(
                            wallet: wallet,
                            specificAccount: specificAccount
                        )
                    }
                }
            }
        }
    }
    
    private func showKey(wallet: WalletContainer, specificAccount: WalletAccount?) {
        guard acceptsUserActions else { return }
        guard let currentWallet = walletsManager.currentWallet(id: wallet.id) else { return }

        let secret: String
        let showingMnemonic = currentWallet.isMnemonic && specificAccount == nil
        
        if let account = specificAccount {
            guard currentWallet.hasAccountMatching(account),
                  let privateKeyString = try? walletsManager.exportPrivateKey(wallet: currentWallet, account: account)
            else { return }
            secret = privateKeyString
        } else if currentWallet.isMnemonic, let mnemonicString = try? walletsManager.exportMnemonic(wallet: currentWallet) {
            secret = mnemonicString
        } else if let privateKeyString = try? walletsManager.exportPrivateKey(wallet: currentWallet) {
            secret = privateKeyString
        } else {
            return
        }
        
        let alert = Alert()
        alert.messageText = showingMnemonic ? Strings.secretWords : Strings.privateKey
        alert.informativeText = secret
        alert.alertStyle = .informational
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.copy)
        presentAlert(alert) { [weak self] response in
            guard let self,
                  !isNativeApprovalReviewInvalidated else { return }
            if response != .alertFirstButtonReturn {
                NSPasteboard.general.clearAndSetString(secret)
            }
        }
    }
    
    private func updateCellModels() {
        guard !wallets.isEmpty else {
            cellModels = [.addAccountOption(.createNew), .addAccountOption(.importExisting)]
            return
        }
        
        cellModels = []
        var privateKeyAccountCellModels = [CellModel]()
        
        for index in 0..<wallets.count {
            let wallet = wallets[index]
            
            guard wallet.isMnemonic else {
                if let account = wallet.accounts.first {
                    privateKeyAccountCellModels.append(.privateKeyAccount(walletIndex: index, account: account))
                }
                continue
            }
            
            let accounts = wallet.accounts
            cellModels.append(.mnemonicWalletHeader(walletIndex: index))
            cellModels.append(contentsOf: (0..<accounts.count).map { CellModel.mnemonicAccount(walletIndex: index, accountIndex: $0) })
        }
        
        if !privateKeyAccountCellModels.isEmpty {
            cellModels.append(.privateKeyWalletsHeader)
            cellModels.append(contentsOf: privateKeyAccountCellModels)
        }
    }
    
    private func showMenuOnCellSelection(row: Int) {
        guard acceptsUserActions else { return }
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { [weak self] _ in
            guard let self, acceptsUserActions else { return }
            var point = NSEvent.mouseLocation
            point.x += 1
            menuForRow(row)?.popUp(positioning: nil, at: point, in: nil)
        }
    }

    private func cancelMenuTracking() {
        addButton.menu?.cancelTrackingWithoutAnimation()
        tableView.menu?.cancelTrackingWithoutAnimation()
        preferencesButton?.menu?.cancelTrackingWithoutAnimation()
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView as? AccountsHeaderRowView)?.cancelMenuTracking()
        }
    }
    
    private func validateSelectedAccounts() {
        guard let specificWalletAccounts = accountSelection?.selectedAccounts else { return }
        for specificWalletAccount in specificWalletAccounts {
            if let wallet = wallets.first(where: { $0.id == specificWalletAccount.walletId }),
               wallet.accounts.contains(specificWalletAccount.account) {
                continue
            } else {
                accountSelection?.selectedAccounts.remove(specificWalletAccount)
            }
        }
    }
    
    private func didClickAccountInSelectionMode(specificWalletAccount: SpecificWalletAccount) {
        let wasSelected = accountSelection?.selectedAccounts.contains(specificWalletAccount) == true
        
        if !wasSelected, let toDeselect = accountSelection?.selectedAccounts.first(where: { $0.account.coin == specificWalletAccount.account.coin }) {
            accountSelection?.selectedAccounts.remove(toDeselect)
        }
        
        if wasSelected {
            accountSelection?.selectedAccounts.remove(specificWalletAccount)
        } else {
            accountSelection?.selectedAccounts.insert(specificWalletAccount)
        }
        
        updatePrimaryButton()
        updateNetworkButtonVisibility()
    }
    
    private func accountCanBeSelected(_ account: WalletAccount) -> Bool {
        return accountSelection?.coinType == nil || accountSelection?.coinType == account.coin
    }
    
}

extension AccountsListViewController: TableViewMenuSource {
    
    func menuForRow(_ row: Int) -> NSMenu? {
        guard acceptsUserActions else { return nil }
        guard let menu = tableView.menu else { return nil }

        let item = cellModels[row]
        let account: WalletAccount
        let wallet: WalletContainer
        
        switch item {
        case .mnemonicWalletHeader, .privateKeyWalletsHeader, .addAccountOption:
            return nil
        case let .mnemonicAccount(walletIndex: walletIndex, accountIndex: accountIndex):
            wallet = wallets[walletIndex]
            account = wallet.accounts[accountIndex]
        case let .privateKeyAccount(walletIndex: walletIndex, account: privateKeyAccount):
            wallet = wallets[walletIndex]
            account = privateKeyAccount
        }
        
        menu.removeAllItems()
        let nameItem = NSMenuItem(title: account.coin.name, action: nil, keyEquivalent: "")
        menu.addItem(nameItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: Strings.copyAddress, action: #selector(didClickCopyAddress(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        
        for (name, url) in account.coin.explorersFor(address: account.address) {
            let menuItem = NSMenuItem(title: name, action: #selector(didClickViewOnExplorer(_:)), keyEquivalent: "")
            menuItem.representedObject = url
            menu.addItem(menuItem)
        }
        
        menu.addItem(.separator())
        let currentName = account.name(walletId: wallet.id)
        let nameActionTitle = currentName == nil ? Strings.setName : Strings.editName
        menu.addItem(NSMenuItem(title: nameActionTitle, action: #selector(didClickEditAccountName(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: wallet.isMnemonic ? Strings.showSecretWords : Strings.showPrivateKey, action: #selector(didClickShowKey(_:)), keyEquivalent: ""))
        
        if wallet.isMnemonic {
            menu.addItem(NSMenuItem(title: Strings.showPrivateKey, action: #selector(didClickShowSpecificPrivateKey(_:)), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: Strings.removeAccount, action: #selector(didClickRemoveAccount(_:)), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: Strings.removeWallet, action: #selector(didClickRemoveWallet(_:)), keyEquivalent: ""))
        }
        
        return menu
    }
    
}

extension AccountsListViewController: AccountsHeaderDelegate {
    
    func didClickEditName(sender: NSTableRowView) {
        guard acceptsUserActions else { return }
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        
        let initialText = WalletsMetadataService.getWalletName(wallet: wallet)
        let nameActionTitle = initialText == nil ? Strings.setName : Strings.editName
        presentTextInputAlert(
            title: nameActionTitle,
            initialText: initialText,
            placeholder: Strings.multicoinWallet
        ) { [weak self] newName in
            guard let self,
                  !isNativeApprovalReviewInvalidated else { return }
            if let newName {
                WalletsMetadataService.saveWalletName(newName, wallet: wallet)
                tableView.reloadData()
            }
        }
    }
    
    func didClickEditAccounts(sender: NSTableRowView) {
        guard acceptsUserActions else { return }
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        
        let editAccountsViewController = instantiate(EditAccountsViewController.self)
        editAccountsViewController.accountSelection = accountSelection
        editAccountsViewController.wallet = wallet
        editAccountsViewController.getBackToRect = tableView.visibleRect
        view.window?.contentViewController = editAccountsViewController
        closeAllPopupsIfNeeded()
    }
    
    func didClickShowSecretWords(sender: NSTableRowView) {
        guard acceptsUserActions else { return }
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        warnBeforeShowingKey(wallet: wallet, specificAccount: nil)
    }
    
    func didClickRemoveWallet(sender: NSTableRowView) {
        guard acceptsUserActions else { return }
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        warnBeforeRemoving(wallet: wallet)
    }
    
}

extension AccountsListViewController: NSTableViewDelegate {
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard acceptsUserActions else { return false }
        guard tableView.selectedRow < 0 else { return false }
        let model = cellModels[row]
        
        let wallet: WalletContainer
        let account: WalletAccount
        
        switch model {
        case let .mnemonicAccount(walletIndex: walletIndex, accountIndex: accountIndex):
            wallet = wallets[walletIndex]
            account = wallet.accounts[accountIndex]
        case let .privateKeyAccount(walletIndex: walletIndex, account: privateKeyAccount):
            wallet = wallets[walletIndex]
            account = privateKeyAccount
        case let .addAccountOption(addAccountOption):
            switch addAccountOption {
            case .createNew:
                didClickCreateAccount()
            case .importExisting:
                didClickImportAccount()
            }
            return false
        case .privateKeyWalletsHeader, .mnemonicWalletHeader:
            return false
        }
        
        if accountSelection != nil {
            if accountCanBeSelected(account) {
                let specificWalletAccount = SpecificWalletAccount(walletId: wallet.id, account: account)
                didClickAccountInSelectionMode(specificWalletAccount: specificWalletAccount)
                tableView.reloadData()
            }
            return false
        } else {
            showMenuOnCellSelection(row: row)
            return true
        }
    }
    
}

extension AccountsListViewController: NSTableViewDataSource {
    
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let model = cellModels[row]
        switch model {
        case let .privateKeyAccount(walletIndex: walletIndex, account: account):
            let wallet = wallets[walletIndex]
            let rowView = tableView.makeViewOfType(AccountCellView.self)
            let specificWalletAccount = SpecificWalletAccount(walletId: wallet.id, account: account)
            let isSelected = accountSelection?.selectedAccounts.contains(specificWalletAccount) == true
            rowView.setup(account: account, walletId: wallet.id, isSelected: isSelected, isDisabled: !accountCanBeSelected(account))
            return rowView
        case let .mnemonicAccount(walletIndex: walletIndex, accountIndex: accountIndex):
            let wallet = wallets[walletIndex]
            let rowView = tableView.makeViewOfType(AccountCellView.self)
            let account = wallet.accounts[accountIndex]
            let specificWalletAccount = SpecificWalletAccount(walletId: wallet.id, account: account)
            let isSelected = accountSelection?.selectedAccounts.contains(specificWalletAccount) == true
            rowView.setup(account: account, walletId: wallet.id, isSelected: isSelected, isDisabled: !accountCanBeSelected(account))
            return rowView
        case let .mnemonicWalletHeader(walletIndex):
            let rowView = tableView.makeViewOfType(AccountsHeaderRowView.self)
            let wallet = wallets[walletIndex]
            let name = WalletsMetadataService.getWalletName(wallet: wallet)
            rowView.setup(walletName: name, multicoinWallet: true, delegate: self)
            return rowView
        case .privateKeyWalletsHeader:
            let rowView = tableView.makeViewOfType(AccountsHeaderRowView.self)
            rowView.setup(walletName: nil, multicoinWallet: false, delegate: nil)
            return rowView
        case let .addAccountOption(addAccountOption):
            let rowView = tableView.makeViewOfType(AddAccountOptionCellView.self)
            rowView.setup(title: addAccountOption.title)
            return rowView
        }
    }
    
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch cellModels[row] {
        case .privateKeyAccount, .mnemonicAccount:
            return 50
        case .addAccountOption:
            return 44
        case .privateKeyWalletsHeader, .mnemonicWalletHeader:
            return 27
        }
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return cellModels.count
    }
    
}

extension AccountsListViewController: NativeApprovalReviewTeardown {

    func invalidateNativeApprovalReview() {
        guard !isNativeApprovalReviewInvalidated else { return }
        isNativeApprovalReviewInvalidated = true
        websiteLogoImageView?.cancelRemoteImageLoad()
        cancelMenuTracking()
        authenticationContext?.invalidate()
        authenticationContext = nil
        accountSelection?.invalidate()
        endAllSheets()
    }

}

extension AccountsListViewController: NSMenuDelegate {
    
    func menuDidClose(_ menu: NSMenu) {
        if menu === addButton.menu {
            menu.removeAllItems()
        } else if let preferencesMenu = preferencesButton?.menu, menu === preferencesMenu {
            menu.removeAllItems()
        } else if menu === tableView.menu {
            tableView.deselectedRow = tableView.selectedRow
            tableView.deselectAll(nil)
        }
    }
    
}

extension AccountsListViewController: NSWindowDelegate {
    
    func windowWillClose(_ notification: Notification) {
        invalidateNativeApprovalReview()
        closeAllPopupsIfNeeded()
    }
    
}
