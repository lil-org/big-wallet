// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa

class AccountsListViewController: NSViewController {

    private let agent = Agent.shared
    private let walletsManager = WalletsManager.shared
    private var cellModels = [CellModel]()
    
    private var chain = EthereumChain.ethereum
    private var didCallCompletion = false
    var onSelectedWallet: ((EthereumChain?, TokenaryWallet?) -> Void)?
    var newWalletId: String?
    
    enum CellModel {
        case wallet
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
    
    private weak var testnetsMenuItem: NSMenuItem?
    @IBOutlet weak var chainButtonHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var chainButtonContainer: NSView!
    @IBOutlet weak var chainButton: NSPopUpButton!
    @IBOutlet weak var addButton: NSButton! {
        didSet {
            let menu = NSMenu()
            addButton.menu = menu
            menu.delegate = self
        }
    }
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var tableView: RightClickTableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
        }
    }
    
    private var wallets: [TokenaryWallet] {
        return walletsManager.wallets
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupAccountsMenu()
        reloadHeader()
        updateCellModels()
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        blinkNewWalletCellIfNeeded()
        view.window?.delegate = self
        promptSafariForLegacyUsersIfNeeded()
    }
    
    private func promptSafariForLegacyUsersIfNeeded() {
        guard Defaults.shouldPromptSafariForLegacyUsers else { return }
        Defaults.shouldPromptSafariForLegacyUsers = false
        Alert.showSafariPrompt()
    }
    
    private func callCompletion(wallet: TokenaryWallet?) {
        if !didCallCompletion {
            didCallCompletion = true
            onSelectedWallet?(chain, wallet)
        }
    }
    
    private func setupAccountsMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: Strings.copyAddress, action: #selector(didClickCopyAddress(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: Strings.viewOnEtherscan, action: #selector(didClickViewOnEtherscan(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: Strings.showAccountKey, action: #selector(didClickExportAccount(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: Strings.removeAccount, action: #selector(didClickRemoveAccount(_:)), keyEquivalent: ""))
        tableView.menu = menu
    }
    
	private func reloadHeader() {
        let canSelectAccount = onSelectedWallet != nil && !wallets.isEmpty
        titleLabel.stringValue = canSelectAccount ? Strings.selectAccountTwoLines : Strings.accounts
        addButton.isHidden = wallets.isEmpty
        chainButtonHeightConstraint.constant = canSelectAccount ? 40 : 15
        chainButtonContainer.isHidden = !canSelectAccount
        if canSelectAccount, chainButton.menu?.items.isEmpty == true {
            let menu = NSMenu()
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
            testnetsMenuItem = submenuItem
            chainButton.menu = menu
        }
    }
    
    @objc private func didBecomeActive() {
        guard view.window?.isVisible == true else { return }
        if let completion = agent.getWalletSelectionCompletionIfShouldSelect() {
            onSelectedWallet = completion
        }
        reloadHeader()
    }
    
    @objc private func didSelectChain(_ sender: AnyObject) {
        guard let menuItem = sender as? NSMenuItem,
              let selectedChain = EthereumChain(rawValue: menuItem.tag) else { return }
        
        if let index = chainButton.menu?.index(of: menuItem), index < 0 {
            let submenu = menuItem.menu
            submenu?.removeItem(menuItem)
            
            if submenu?.items.isEmpty == true, let testnetsMenuItem = testnetsMenuItem {
                testnetsMenuItem.menu?.removeItem(testnetsMenuItem)
                self.testnetsMenuItem = nil
            }
            
            chainButton.menu?.addItem(menuItem)
            chainButton.select(menuItem)
        }
        
        chain = selectedChain
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
    
    @objc private func didClickCreateAccount() {
        let alert = Alert()
        alert.messageText = Strings.backUpNewAccount
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
        reloadHeader()
        updateCellModels()
        tableView.reloadData()
        blinkNewWalletCellIfNeeded()
        showKey(wallet: wallet, mnemonic: true)
    }
    
    private func blinkNewWalletCellIfNeeded() {
        guard let id = newWalletId else { return }
        newWalletId = nil
        guard let row = wallets.firstIndex(where: { $0.id == id }), row < cellModels.count else { return }
        tableView.scrollRowToVisible(row)
        (tableView.rowView(atRow: row, makeIfNecessary: true) as? AccountCellView)?.blink()
    }
    
    @objc private func didClickImportAccount() {
        let importViewController = instantiate(ImportViewController.self)
        importViewController.onSelectedWallet = onSelectedWallet
        view.window?.contentViewController = importViewController
    }
    
    @objc private func didClickViewOnEtherscan(_ sender: AnyObject) {
        let row = tableView.deselectedRow
        guard row >= 0, let address = wallets[row].ethereumAddress else { return }
        if let url = URL(string: "https://etherscan.io/address/\(address)") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc private func didClickCopyAddress(_ sender: AnyObject) {
        let row = tableView.deselectedRow
        guard row >= 0, let address = wallets[row].ethereumAddress else { return }
        NSPasteboard.general.clearAndSetString(address)
    }

    @objc private func didClickRemoveAccount(_ sender: AnyObject) {
        let row = tableView.deselectedRow
        guard row >= 0 else { return }
        let alert = Alert()
        alert.messageText = Strings.removedAccountsCantBeRecovered
        alert.alertStyle = .critical
        alert.addButton(withTitle: Strings.removeAnyway)
        alert.addButton(withTitle: Strings.cancel)
        if alert.runModal() == .alertFirstButtonReturn {
            agent.askAuthentication(on: view.window, getBackTo: self, onStart: false, reason: .removeAccount) { [weak self] allowed in
                Window.activateWindow(self?.view.window)
                if allowed {
                    self?.removeAccountAtIndex(row)
                }
            }
        }
    }
    
    @objc private func didClickExportAccount(_ sender: AnyObject) {
        let row = tableView.deselectedRow
        guard row >= 0 else { return }
        let isMnemonic = wallets[row].isMnemonic
        let alert = Alert()
        
        alert.messageText = "\(isMnemonic ? "Secret words give" : "Private key gives") full access to your funds."
        alert.alertStyle = .critical
        alert.addButton(withTitle: Strings.iUnderstandTheRisks)
        alert.addButton(withTitle: Strings.cancel)
        if alert.runModal() == .alertFirstButtonReturn {
            let reason: AuthenticationReason = isMnemonic ? .showSecretWords : .showPrivateKey
            agent.askAuthentication(on: view.window, getBackTo: self, onStart: false, reason: reason) { [weak self] allowed in
                Window.activateWindow(self?.view.window)
                if allowed {
                    self?.showKey(index: row, mnemonic: isMnemonic)
                }
            }
        }
    }
    
    private func showKey(index: Int, mnemonic: Bool) {
        showKey(wallet: wallets[index], mnemonic: mnemonic)
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
        
        let alert = Alert()
        alert.messageText = mnemonic ? Strings.secretWords : Strings.privateKey
        alert.informativeText = secret
        alert.alertStyle = .informational
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.copy)
        if alert.runModal() != .alertFirstButtonReturn {
            NSPasteboard.general.clearAndSetString(secret)
        }
    }
    
    private func removeAccountAtIndex(_ index: Int) {
        let wallet = wallets[index]
        try? walletsManager.delete(wallet: wallet)
        reloadHeader()
        updateCellModels()
        tableView.reloadData()
    }
    
    private func updateCellModels() {
        if wallets.isEmpty {
            cellModels = [.addAccountOption(.createNew), .addAccountOption(.importExisting)]
            tableView.shouldShowRightClickMenu = false
        } else {
            cellModels = Array(repeating: CellModel.wallet, count: wallets.count)
            tableView.shouldShowRightClickMenu = true
        }
    }
    
}

extension AccountsListViewController: NSTableViewDelegate {
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView.selectedRow < 0 else { return false }
        let model = cellModels[row]
        
        switch model {
        case .wallet:
            let wallet = wallets[row]
            if onSelectedWallet != nil {
                callCompletion(wallet: wallet)
            } else {
                Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { [weak self] _ in
                    var point = NSEvent.mouseLocation
                    point.x += 1
                    self?.tableView.menu?.popUp(positioning: nil, at: point, in: nil)
                }
            }
            return true
        case let .addAccountOption(addAccountOption):
            switch addAccountOption {
            case .createNew:
                didClickCreateAccount()
            case .importExisting:
                didClickImportAccount()
            }
            return false
        }
    }
    
}

extension AccountsListViewController: NSTableViewDataSource {
    
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let model = cellModels[row]
        switch model {
        case .wallet:
            let wallet = wallets[row]
            let rowView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("AccountCellView"), owner: self) as? AccountCellView
            rowView?.setup(address: wallet.ethereumAddress ?? "")
            return rowView
        case let .addAccountOption(addAccountOption):
            let rowView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("AddAccountOptionCellView"), owner: self) as? AddAccountOptionCellView
            rowView?.setup(title: addAccountOption.title)
            return rowView
        }
    }
    
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .wallet = cellModels[row] {
            return 50
        } else {
            return 44
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
        callCompletion(wallet: nil)
    }
    
}
