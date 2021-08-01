// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class AccountsListViewController: NSViewController {

    private let agent = Agent.shared
    private let accountsService = AccountsService.shared
    private var accounts = [AccountWithKey]()
    private var cellModels = [CellModel]()
    
    var onSelectedAccount: ((AccountWithKey) -> Void)?
    
    enum CellModel {
        case account(AccountWithKey)
        case addAccountOption(AddAccountOption)
    }
    
    enum AddAccountOption {
        case createNew, importExisting
        
        var title: String {
            switch self {
            case .createNew:
                return "🌱  Create New"
            case .importExisting:
                return "💼  Import Existing"
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
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var tableView: RightClickTableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupAccountsMenu()
        reloadAccounts()
        reloadTitle()
        updateCellModels()
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    
    private func setupAccountsMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Copy address", action: #selector(didClickCopyAddress(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "View on Zerion", action: #selector(didClickViewOnZerion(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show private key", action: #selector(didClickExportAccount(_:)), keyEquivalent: "")) // TODO: show different texts for secret words export
        menu.addItem(NSMenuItem(title: "Remove account", action: #selector(didClickRemoveAccount(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "How to WalletConnect?", action: #selector(showInstructionsAlert), keyEquivalent: ""))
        tableView.menu = menu
    }
    
    private func reloadAccounts() {
        accounts = accountsService.getAccounts()
    }
    
    private func reloadTitle() {
        titleLabel.stringValue = onSelectedAccount != nil && !accounts.isEmpty ? "Select\nAccount" : "Accounts"
        addButton.isHidden = accounts.isEmpty
    }
    
    @objc private func didBecomeActive() {
        guard view.window?.isVisible == true else { return }
        if let completion = agent.getAccountSelectionCompletionIfShouldSelect() {
            onSelectedAccount = completion
        }
        reloadTitle()
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
        accountsService.createAccount()
        reloadAccounts()
        reloadTitle()
        updateCellModels()
        tableView.reloadData()
        // TODO: show backup phrase
    }
    
    @objc private func didClickImportAccount() {
        let importViewController = instantiate(ImportViewController.self)
        importViewController.onSelectedAccount = onSelectedAccount
        view.window?.contentViewController = importViewController
    }
    
    @objc private func didClickViewOnZerion(_ sender: AnyObject) {
        let row = tableView.deselectedRow
        guard row >= 0 else { return }
        let address = accounts[row].address
        if let url = URL(string: "https://app.zerion.io/\(address)/overview") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc private func didClickCopyAddress(_ sender: AnyObject) {
        let row = tableView.deselectedRow
        guard row >= 0 else { return }
        NSPasteboard.general.clearAndSetString(accounts[row].address)
    }

    @objc private func didClickRemoveAccount(_ sender: AnyObject) {
        let row = tableView.deselectedRow
        guard row >= 0 else { return }
        let alert = Alert()
        alert.messageText = "Removed accounts can't be recovered."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Remove anyway")
        alert.addButton(withTitle: "Cancel")
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
        // TODO: show different texts for secret words export
        let row = tableView.deselectedRow
        guard row >= 0 else { return }
        let alert = Alert()
        alert.messageText = "Private key gives full access to your funds."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "I understand the risks")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            agent.askAuthentication(on: view.window, getBackTo: self, onStart: false, reason: .showPrivateKey) { [weak self] allowed in
                Window.activateWindow(self?.view.window)
                if allowed {
                    self?.showPrivateKey(index: row)
                }
            }
        }
    }
    
    private func showPrivateKey(index: Int) {
        let privateKey = accounts[index].privateKey
        let alert = Alert()
        alert.messageText = "Private key"
        alert.informativeText = privateKey
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy")
        if alert.runModal() != .alertFirstButtonReturn {
            NSPasteboard.general.clearAndSetString(privateKey)
        }
    }
    
    @objc private func showInstructionsAlert() {
        Alert.showWalletConnectInstructions()
    }
    
    private func removeAccountAtIndex(_ index: Int) {
        accountsService.removeAccount(accounts[index])
        accounts.remove(at: index)
        reloadTitle()
        updateCellModels()
        tableView.reloadData()
    }
    
    private func updateCellModels() {
        if accounts.isEmpty {
            cellModels = [.addAccountOption(.createNew), .addAccountOption(.importExisting)]
            tableView.shouldShowRightClickMenu = false
        } else {
            cellModels = accounts.map { .account($0) }
            tableView.shouldShowRightClickMenu = true
        }
    }
    
}

extension AccountsListViewController: NSTableViewDelegate {
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView.selectedRow < 0 else { return false }
        let model = cellModels[row]
        
        switch model {
        case let .account(account):
            if let onSelectedAccount = onSelectedAccount {
                onSelectedAccount(account)
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
        case let .account(account):
            let rowView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("AccountCellView"), owner: self) as? AccountCellView
            rowView?.setup(address: account.address)
            return rowView
        case let .addAccountOption(addAccountOption):
            let rowView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("AddAccountOptionCellView"), owner: self) as? AddAccountOptionCellView
            rowView?.setup(title: addAccountOption.title)
            return rowView
        }
    }
    
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .account = cellModels[row] {
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
        } else {
            tableView.deselectedRow = tableView.selectedRow
            tableView.deselectAll(nil)
        }
    }
    
}
