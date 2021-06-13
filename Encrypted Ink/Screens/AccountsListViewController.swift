// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class AccountsListViewController: NSViewController {

    private var accounts = AccountsService.getAccounts()
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var tableView: NSTableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    @IBAction func addButtonTapped(_ sender: NSButton) {
        if let importViewController = storyboard?.instantiateController(withIdentifier: "ImportViewController") as? ImportViewController {
            view.window?.contentViewController = importViewController
        }
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
