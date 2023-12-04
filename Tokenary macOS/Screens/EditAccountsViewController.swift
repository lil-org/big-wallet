// Copyright © 2022 Tokenary. All rights reserved.

import Cocoa
import WalletCore

class EditAccountsViewController: NSViewController {
    
    var wallet: TokenaryWallet!
    var getBackToRect: CGRect?
    var selectAccountAction: SelectAccountAction?
    
    struct PreviewAccountCellModel {
        let account: Account
        var isEnabled: Bool
    }
    
    private let walletsManager = WalletsManager.shared
    private var cellModels = [PreviewAccountCellModel]()
    private let previewAccountsQueue = DispatchQueue(label: "mac.tokenary.io.accounts", qos: .userInitiated)
    private var page = 1
    private var requestedPreviewFor: Int?
    private var lastPreviewDate = Date()
    
    @IBOutlet weak var tableView: RightClickTableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
        }
    }
    @IBOutlet weak var okButton: NSButton!
    @IBOutlet weak var titleLabel: NSTextField!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let previewAccounts = try? walletsManager.previewAccounts(wallet: wallet, page: 0) else { return }
        cellModels = previewAccounts.map { account, isEnabled in
            return PreviewAccountCellModel(account: account, isEnabled: isEnabled)
        }
    }
    
    @IBAction func cancelButtonTapped(_ sender: Any) {
        showAccountsList()
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        let newAccounts: [Account] = cellModels.compactMap { model in
            if model.isEnabled {
                return model.account
            } else {
                return nil
            }
        }
        let accountsChanged = false // TODO: implement
        if accountsChanged {
            do {
                // TODO: update accounts
                showAccountsList()
            } catch {
                Alert.showWithMessage(Strings.somethingWentWrong, style: .informational)
            }
        } else {
            showAccountsList()
        }
    }
    
    private func showAccountsList() {
        let accountsListViewController = instantiate(AccountsListViewController.self)
        accountsListViewController.selectAccountAction = selectAccountAction
        accountsListViewController.getBackToRect = getBackToRect
        view.window?.contentViewController = accountsListViewController
    }
    
    private func toggleCoinDerivation(row: Int) {
        cellModels[row].isEnabled.toggle()
        okButton.isEnabled = cellModels.contains(where: { $0.isEnabled })
    }
    
    private func previewMoreAccountsIfNeeded() {
        guard requestedPreviewFor != cellModels.count else { return }
        requestedPreviewFor = cellModels.count
        previewMoreAccounts()
    }
    
    private func previewMoreAccounts() {
        guard Date().timeIntervalSince(lastPreviewDate) > 1.31 else {
            previewAccountsQueue.asyncAfter(deadline: .now() + .milliseconds(1310)) { [weak self] in
                self?.previewMoreAccounts()
            }
            return
        }
        lastPreviewDate = Date()
        previewAccountsQueue.async { [weak self] in
            guard let wallet = self?.wallet,
                  let page = self?.page,
                  let previewAccounts = try? self?.walletsManager.previewAccounts(wallet: wallet, page: page) else { return }
            DispatchQueue.main.async {
                let newCellModels = previewAccounts.map { account, isEnabled in
                    return PreviewAccountCellModel(account: account, isEnabled: isEnabled)
                }
                self?.cellModels.append(contentsOf: newCellModels)
                self?.page += 1
                if let currentCount = self?.cellModels.count {
                    let range = (currentCount - newCellModels.count)..<currentCount
                    self?.tableView.insertRows(at: IndexSet(integersIn: range))
                }
            }
        }
    }
    
}

extension EditAccountsViewController: PreviewAccountCellDelegate {
    
    func didToggleCheckmark(_ sender: NSTableRowView) {
        let row = tableView.row(for: sender)
        guard row >= 0 else { return }
        toggleCoinDerivation(row: row)
    }
    
}

extension EditAccountsViewController: NSTableViewDelegate {
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? PreviewAccountCellView {
            rowView.toggle()
            toggleCoinDerivation(row: row)
        }
        return false
    }
    
}

extension EditAccountsViewController: NSTableViewDataSource {
    
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let model = cellModels[row]
        let rowView = tableView.makeViewOfType(PreviewAccountCellView.self, owner: self)
        rowView.setup(title: model.account.croppedAddress, index: row, image: model.account.image, isEnabled: model.isEnabled, delegate: self)
        
        if row == cellModels.count - 1 {
            previewMoreAccountsIfNeeded()
        }
        
        return rowView
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return cellModels.count
    }
    
}
