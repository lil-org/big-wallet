// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class AccountsListViewController: NSViewController {

    private let agent = Agent.shared
    private var accounts = [Account]()
    
    var onSelectedAccount: ((Account) -> Void)?
    
    static func with(preloadedAccounts: [Account]) -> AccountsListViewController {
        let new = instantiate(AccountsListViewController.self)
        new.accounts = preloadedAccounts
        return new
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
        
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Copy address", action: #selector(didClickCopyAddress(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show private key", action: #selector(didClickExportAccount(_:)), keyEquivalent: "")) // TODO: show different texts for secret words export
        menu.addItem(NSMenuItem(title: "Remove account", action: #selector(didClickRemoveAccount(_:)), keyEquivalent: ""))
        tableView.menu = menu
        
        if accounts.isEmpty {
            reloadAccounts()
        }
        
        reloadTitle()
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    
    private func reloadAccounts() {
        accounts = AccountsService.getAccounts()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func reloadTitle() {
        titleLabel.stringValue = onSelectedAccount != nil ? "Select\nAccount" : "Accounts"
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
        createItem.attributedTitle = NSAttributedString(string: "🌱  Create New", attributes: [.font: font])
        importItem.attributedTitle = NSAttributedString(string: "💼  Import Existing", attributes: [.font: font])
        menu?.addItem(createItem)
        menu?.addItem(importItem)
        
        var origin = sender.frame.origin
        origin.x += sender.frame.width
        origin.y += sender.frame.height
        menu?.popUp(positioning: createItem, at: origin, in: view)
    }
    
    @objc private func didClickCreateAccount() {
        AccountsService.createAccount()
        reloadAccounts()
        tableView.reloadData()
        // TODO: show backup phrase
    }
    
    @objc private func didClickImportAccount() {
        let importViewController = instantiate(ImportViewController.self)
        importViewController.onSelectedAccount = onSelectedAccount
        view.window?.contentViewController = importViewController
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
            agent.askAuthentication(on: view.window, getBackTo: self, onStart: false, reason: "Remove account") { [weak self] allowed in
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
            agent.askAuthentication(on: view.window, getBackTo: self, onStart: false, reason: "Show private key") { [weak self] allowed in
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
    
    private func showInstructionsAlert() {
        let alert = Alert()
        alert.messageText = "How to start?"
        alert.informativeText = "1. Open your favourite dapp.\n\n2. Press “Copy to clipboard”\nunder WalletConnect QR code.\n\n3. Launch Encrypted Ink."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Zerion")
        if alert.runModal() != .alertFirstButtonReturn, let url = URL(string: "https://app.zerion.io") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func removeAccountAtIndex(_ index: Int) {
        AccountsService.removeAccount(accounts[index])
        accounts.remove(at: index)
        tableView.reloadData()
    }
    
}

extension AccountsListViewController: NSTableViewDelegate {
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if let onSelectedAccount = onSelectedAccount {
            let account = accounts[row]
            onSelectedAccount(account)
        } else {
            Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { [weak self] _ in
                self?.tableView.menu?.popUp(positioning: tableView.menu?.items.first, at: NSEvent.mouseLocation, in: nil)
            }
        }
        return true
    }
    
}

extension AccountsListViewController: NSTableViewDataSource {
    
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("AccountCellView"), owner: self) as? AccountCellView
        rowView?.setup(address: accounts[row].address)
        return rowView
    }
    
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 50
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return accounts.count
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
