// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class AccountsListViewController: NSViewController {

    private var accounts = [Account]()
    
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
    }
    
    @IBAction func addButtonTapped(_ sender: NSButton) {
        let importViewController = instantiate(ImportViewController.self)
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
        guard row >= 0 else { return }
        AccountsService.removeAccount(accounts[row])
        accounts.remove(at: row)
        tableView.reloadData()
    }
    
}

extension AccountsListViewController: NSTableViewDelegate {
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // TODO: jump somewhere else
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
