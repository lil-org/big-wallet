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
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var tableView: NSTableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy address", action: #selector(didClickCopyAddress(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Remove account", action: #selector(didClickRemoveAccount(_:)), keyEquivalent: ""))
        tableView.menu = menu
        
        if accounts.isEmpty {
            accounts = AccountsService.getAccounts()
        }
        
        reloadTitle()
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
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
        let importViewController = instantiate(ImportViewController.self)
        importViewController.onSelectedAccount = onSelectedAccount
        view.window?.contentViewController = importViewController
    }
    
    @objc private func didClickCopyAddress(_ sender: AnyObject) {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(accounts[row].address, forType: .string)
    }

    @objc private func didClickRemoveAccount(_ sender: AnyObject) {
        let row = tableView.clickedRow
        
        let alert = Alert()
        alert.messageText = "Removed accounts can't be recovered."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove anyway")
        if alert.runModal() != .alertFirstButtonReturn {
            guard row >= 0 else { return }
            agent.askAuthentication(on: view.window, getBackTo: self, requireAppPasswordScreen: false, reason: "Remove account") { [weak self] allowed in
                Window.activateWindow(self?.view.window)
                if allowed {
                    self?.removeAccountAtIndex(row)
                }
            }
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
            return true
        } else {
            showInstructionsAlert()
            return false
        }
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
