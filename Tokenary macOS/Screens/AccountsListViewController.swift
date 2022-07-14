// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa
import WalletCore

class AccountsListViewController: NSViewController {

    private let agent = Agent.shared
    private let walletsManager = WalletsManager.shared
    private var cellModels = [CellModel]()
    
    private var chain = EthereumChain.ethereum
    private var didCallCompletion = false
    var onSelectedWallet: ((EthereumChain?, TokenaryWallet?, Account?) -> Void)?
    var newWalletId: String?
    var getBackToRect: CGRect?
    
    enum CellModel {
        case mnemonicWalletHeader(walletIndex: Int)
        case privateKeyWalletsHeader
        case mnemonicAccount(walletIndex: Int, accountIndex: Int)
        case privateKeyAccount(walletIndex: Int)
        case addAccountOption(AddAccountOption)
    }
    
    enum AddAccountOption {
        case createNew, importExisting
        
        var title: String {
            switch self {
            case .createNew:
                return "🌱  " + Strings.createNew
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
    
    @IBOutlet weak var networkButton: NSButton!
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
    
    private var wallets: [TokenaryWallet] {
        return walletsManager.wallets
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        reloadHeader()
        updateCellModels()
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: Notification.Name.walletsChanged, object: nil)
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        getBackToRectIfNeeded()
        blinkNewWalletCellIfNeeded()
        view.window?.delegate = self
        promptSafariForLegacyUsersIfNeeded()
    }
    
    private func promptSafariForLegacyUsersIfNeeded() {
        guard Defaults.shouldPromptSafariForLegacyUsers else { return }
        Defaults.shouldPromptSafariForLegacyUsers = false
        Alert.showSafariPrompt()
    }
    
    private func callCompletion(wallet: TokenaryWallet?, account: Account?) {
        if !didCallCompletion {
            didCallCompletion = true
            onSelectedWallet?(chain, wallet, account)
        }
    }
    
    private func reloadHeader() {
        let canSelectAccount = onSelectedWallet != nil && !wallets.isEmpty
        titleLabel.stringValue = canSelectAccount ? Strings.selectAccountTwoLines : Strings.wallets
        addButton.isHidden = wallets.isEmpty
        
        if canSelectAccount, networkButton.isHidden {
            networkButton.isHidden = false
            let menu = NSMenu()
            let titleItem = NSMenuItem(title: Strings.selectNetworkOptionally, action: nil, keyEquivalent: "")
            menu.addItem(titleItem)
            menu.addItem(.separator())
            for mainnet in EthereumChain.allMainnets {
                let item = NSMenuItem(title: mainnet.name, action: #selector(didSelectChain(_:)), keyEquivalent: "")
                item.tag = mainnet.id
                menu.addItem(item)
            }
            
            let submenuItem = NSMenuItem()
            submenuItem.title = Strings.testnets
            let submenu = NSMenu()
            for testnet in EthereumChain.allTestnets {
                let item = NSMenuItem(title: testnet.name, action: #selector(didSelectChain(_:)), keyEquivalent: "")
                item.tag = testnet.id
                submenu.addItem(item)
            }
            
            submenuItem.submenu = submenu
            menu.addItem(.separator())
            menu.addItem(submenuItem)
            networkButton.menu = menu
        } else if !canSelectAccount, !networkButton.isHidden {
            networkButton.isHidden = true
        }
    }
    
    @objc private func didBecomeActive() {
        guard view.window?.isVisible == true else { return }
        if let completion = agent.getWalletSelectionCompletionIfShouldSelect() {
            onSelectedWallet = completion
        }
        reloadHeader()
    }
    
    @IBAction func addButtonTapped(_ sender: NSButton) {
        let menu = sender.menu
        
        let createItem = NSMenuItem(title: "", action: #selector(didClickCreateAccount), keyEquivalent: "")
        let importItem = NSMenuItem(title: "", action: #selector(didClickImportAccount), keyEquivalent: "")
        let font = NSFont.systemFont(ofSize: 21, weight: .bold)
        createItem.attributedTitle = NSAttributedString(string: AddAccountOption.createNew.title, attributes: [.font: font])
        importItem.attributedTitle = NSAttributedString(string: AddAccountOption.importExisting.title, attributes: [.font: font])
        menu?.addItem(createItem)
        menu?.addItem(importItem)
        
        var origin = sender.frame.origin
        origin.x += sender.frame.width
        origin.y += sender.frame.height
        menu?.popUp(positioning: nil, at: origin, in: view)
    }
    
    @IBAction func networkButtonTapped(_ sender: NSButton) {
        var origin = sender.frame.origin
        origin.x += sender.frame.width
        origin.y += sender.frame.height
        sender.menu?.popUp(positioning: nil, at: origin, in: view)
    }
    
    @objc private func didSelectChain(_ sender: AnyObject) {
        guard let menuItem = sender as? NSMenuItem,
              let selectedChain = EthereumChain(rawValue: menuItem.tag) else { return }
        networkButton.menu?.items[0].title = selectedChain.name + " — " + Strings.isSelected
        networkButton.contentTintColor = .controlAccentColor
        chain = selectedChain
    }

    @objc private func didClickCreateAccount() {
        let alert = Alert()
        alert.messageText = Strings.backUpNewWallet
        alert.informativeText = Strings.youWillSeeSecretWords
        alert.alertStyle = .critical
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.cancel)
        if alert.runModal() == .alertFirstButtonReturn {
            createNewAccountAndShowSecretWords()
        }
    }
    
    private func createNewAccountAndShowSecretWords() {
        guard let wallet = try? walletsManager.createWallet() else { return }
        newWalletId = wallet.id
        blinkNewWalletCellIfNeeded()
        showKey(wallet: wallet)
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
            } else if case let .privateKeyAccount(walletIndex: walletIndex) = model {
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
        let importViewController = instantiate(ImportViewController.self)
        importViewController.onSelectedWallet = onSelectedWallet
        view.window?.contentViewController = importViewController
    }
    
    private func walletForRow(_ row: Int) -> TokenaryWallet? {
        guard row >= 0 else { return nil }
        let item = cellModels[row]
        switch item {
        case let .privateKeyAccount(walletIndex: walletIndex):
            return wallets[walletIndex]
        case let .mnemonicAccount(walletIndex: walletIndex, accountIndex: _):
            return wallets[walletIndex]
        case let .mnemonicWalletHeader(walletIndex: walletIndex):
            return wallets[walletIndex]
        default:
            return nil
        }
    }
    
    private func accountForRow(_ row: Int) -> Account? {
        guard row >= 0 else { return nil }
        let item = cellModels[row]
        switch item {
        case let .privateKeyAccount(walletIndex: walletIndex):
            return wallets[walletIndex].accounts.first
        case let .mnemonicAccount(walletIndex: walletIndex, accountIndex: accountIndex):
            return wallets[walletIndex].accounts[accountIndex]
        default:
            return nil
        }
    }
    
    @objc private func didClickViewOnExplorer(_ sender: AnyObject) {
        let row = tableView.deselectedRow
        guard let account = accountForRow(row) else { return }
        let address = account.address
        NSWorkspace.shared.open(account.coin.explorerURL(address: address))
    }
    
    @objc private func didClickCopyAddress(_ sender: AnyObject) {
        let row = tableView.deselectedRow
        guard let address = accountForRow(row)?.address else { return }
        NSPasteboard.general.clearAndSetString(address)
    }

    @objc private func didClickRemoveWallet(_ sender: AnyObject) {
        let row = tableView.deselectedRow
        if let wallet = walletForRow(row) {
            warnBeforeRemoving(wallet: wallet)
        }
    }
    
    @objc private func didClickRemoveAccount(_ sender: AnyObject) {
        let row = tableView.deselectedRow
        guard let wallet = walletForRow(row), let account = accountForRow(row) else { return }
        
        guard wallet.accounts.count > 1 else {
            warnOnLastAccountRemovalAttempt(wallet: wallet)
            return
        }
        
        do {
            try walletsManager.update(wallet: wallet, removeAccounts: [account])
        } catch {
            Alert.showWithMessage(Strings.somethingWentWrong, style: .informational)
        }
    }
    
    private func warnOnLastAccountRemovalAttempt(wallet: TokenaryWallet) {
        let alert = Alert()
        alert.messageText = Strings.removingTheLastAccount
        alert.alertStyle = .critical
        
        alert.addButton(withTitle: Strings.cancel)
        alert.addButton(withTitle: Strings.removeAnyway)
        if alert.runModal() != .alertFirstButtonReturn {
            warnBeforeRemoving(wallet: wallet)
        }
    }
    
    private func warnBeforeRemoving(wallet: TokenaryWallet) {
        let alert = Alert()
        alert.messageText = Strings.removedWalletsCantBeRecovered
        alert.alertStyle = .critical
        alert.addButton(withTitle: Strings.removeAnyway)
        alert.addButton(withTitle: Strings.cancel)
        if alert.runModal() == .alertFirstButtonReturn {
            agent.askAuthentication(on: view.window, getBackTo: self, onStart: false, reason: .removeWallet) { [weak self] allowed in
                Window.activateWindow(self?.view.window)
                if allowed {
                    self?.removeWallet(wallet)
                }
            }
        }
    }
    
    private func removeWallet(_ wallet: TokenaryWallet) {
        try? walletsManager.delete(wallet: wallet)
    }
    
    @objc private func walletsChanged() {        
        reloadHeader()
        updateCellModels()
        tableView.reloadData()
    }
    
    @objc private func didClickShowKey(_ sender: AnyObject) {
        let row = tableView.deselectedRow
        guard let wallet = walletForRow(row) else { return }
        warnBeforeShowingKey(wallet: wallet)
    }
    
    private func warnBeforeShowingKey(wallet: TokenaryWallet) {
        let alert = Alert()
        alert.messageText = wallet.isMnemonic ? Strings.secretWordsGiveFullAccess : Strings.privateKeyGivesFullAccess
        alert.alertStyle = .critical
        alert.addButton(withTitle: Strings.iUnderstandTheRisks)
        alert.addButton(withTitle: Strings.cancel)
        if alert.runModal() == .alertFirstButtonReturn {
            let reason: AuthenticationReason = wallet.isMnemonic ? .showSecretWords : .showPrivateKey
            agent.askAuthentication(on: view.window, getBackTo: self, onStart: false, reason: reason) { [weak self] allowed in
                Window.activateWindow(self?.view.window)
                if allowed {
                    self?.showKey(wallet: wallet)
                }
            }
        }
    }
    
    private func showKey(wallet: TokenaryWallet) {
        let secret: String
        if wallet.isMnemonic, let mnemonicString = try? walletsManager.exportMnemonic(wallet: wallet) {
            secret = mnemonicString
        } else if let data = try? walletsManager.exportPrivateKey(wallet: wallet) {
            secret = data.hexString
        } else {
            return
        }
        
        let alert = Alert()
        alert.messageText = wallet.isMnemonic ? Strings.secretWords : Strings.privateKey
        alert.informativeText = secret
        alert.alertStyle = .informational
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.copy)
        if alert.runModal() != .alertFirstButtonReturn {
            NSPasteboard.general.clearAndSetString(secret)
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
                privateKeyAccountCellModels.append(.privateKeyAccount(walletIndex: index))
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
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { [weak self] _ in
            var point = NSEvent.mouseLocation
            point.x += 1
            self?.menuForRow(row)?.popUp(positioning: nil, at: point, in: nil)
        }
    }
    
}

extension AccountsListViewController: TableViewMenuSource {
    
    func menuForRow(_ row: Int) -> NSMenu? {
        guard let menu = tableView.menu else { return nil }

        let item = cellModels[row]
        let account: Account
        let wallet: TokenaryWallet
        
        switch item {
        case .mnemonicWalletHeader, .privateKeyWalletsHeader, .addAccountOption:
            return nil
        case let .mnemonicAccount(walletIndex: walletIndex, accountIndex: accountIndex):
            wallet = wallets[walletIndex]
            account = wallet.accounts[accountIndex]
        case let .privateKeyAccount(walletIndex: walletIndex):
            wallet = wallets[walletIndex]
            account = wallet.accounts[0]
        }
        
        menu.removeAllItems()
        let nameItem = NSMenuItem(title: account.coin.name, action: nil, keyEquivalent: "")
        menu.addItem(nameItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: Strings.copyAddress, action: #selector(didClickCopyAddress(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: account.coin.viewOnExplorerTitle, action: #selector(didClickViewOnExplorer(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: wallet.isMnemonic ? Strings.showSecretWords : Strings.showPrivateKey, action: #selector(didClickShowKey(_:)), keyEquivalent: ""))
        
        if wallet.isMnemonic {
            menu.addItem(NSMenuItem(title: Strings.removeAccount, action: #selector(didClickRemoveAccount(_:)), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: Strings.removeWallet, action: #selector(didClickRemoveWallet(_:)), keyEquivalent: ""))
        }
        
        return menu
    }
    
}

extension AccountsListViewController: AccountsHeaderDelegate {
    
    func didClickEditAccounts(sender: NSTableRowView) {
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        
        let editAccountsViewController = instantiate(EditAccountsViewController.self)
        editAccountsViewController.onSelectedWallet = onSelectedWallet
        editAccountsViewController.wallet = wallet
        editAccountsViewController.getBackToRect = tableView.visibleRect
        view.window?.contentViewController = editAccountsViewController
    }
    
    func didClickShowSecretWords(sender: NSTableRowView) {
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        warnBeforeShowingKey(wallet: wallet)
    }
    
    func didClickRemoveWallet(sender: NSTableRowView) {
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        warnBeforeRemoving(wallet: wallet)
    }
    
}

extension AccountsListViewController: NSTableViewDelegate {
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView.selectedRow < 0 else { return false }
        let model = cellModels[row]
        
        let wallet: TokenaryWallet
        let account: Account
        
        switch model {
        case let .mnemonicAccount(walletIndex: walletIndex, accountIndex: accountIndex):
            wallet = wallets[walletIndex]
            account = wallet.accounts[accountIndex]
        case let .privateKeyAccount(walletIndex: walletIndex):
            wallet = wallets[walletIndex]
            account = wallet.accounts[0]
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
        
        if onSelectedWallet != nil {
            callCompletion(wallet: wallet, account: account)
        } else {
            showMenuOnCellSelection(row: row)
        }
        return true
    }
    
}

extension AccountsListViewController: NSTableViewDataSource {
    
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let model = cellModels[row]
        switch model {
        case let .privateKeyAccount(walletIndex: walletIndex):
            let wallet = wallets[walletIndex]
            let rowView = tableView.makeViewOfType(AccountCellView.self, owner: self)
            rowView.setup(account: wallet.accounts[0])
            return rowView
        case let .mnemonicAccount(walletIndex: walletIndex, accountIndex: accountIndex):
            let wallet = wallets[walletIndex]
            let rowView = tableView.makeViewOfType(AccountCellView.self, owner: self)
            rowView.setup(account: wallet.accounts[accountIndex])
            return rowView
        case .mnemonicWalletHeader:
            let rowView = tableView.makeViewOfType(AccountsHeaderRowView.self, owner: self)
            rowView.setup(multicoinWallet: true, delegate: self)
            return rowView
        case .privateKeyWalletsHeader:
            let rowView = tableView.makeViewOfType(AccountsHeaderRowView.self, owner: self)
            rowView.setup(multicoinWallet: false, delegate: nil)
            return rowView
        case let .addAccountOption(addAccountOption):
            let rowView = tableView.makeViewOfType(AddAccountOptionCellView.self, owner: self)
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

extension AccountsListViewController: NSMenuDelegate {
    
    func menuDidClose(_ menu: NSMenu) {
        if menu === addButton.menu {
            menu.removeAllItems()
        } else if menu === tableView.menu {
            tableView.deselectedRow = tableView.selectedRow
            tableView.deselectAll(nil)
        }
    }
    
}

extension AccountsListViewController: NSWindowDelegate {
    
    func windowWillClose(_ notification: Notification) {
        callCompletion(wallet: nil, account: nil)
    }
    
}
