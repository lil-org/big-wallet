// Copyright © 2022 Tokenary. All rights reserved.

import Cocoa
import WalletCore

class EditAccountsViewController: NSViewController {
    
    var wallet: TokenaryWallet!
    var getBackToRect: CGRect?
    var selectAccountAction: SelectAccountAction?
    
    struct CoinDerivationCellModel {
        let coinDerivation: CoinDerivation
        var isEnabled: Bool
    }
    
    private let walletsManager = WalletsManager.shared
    private var initialDerivations = [CoinDerivation]()
    private var cellModels = [CoinDerivationCellModel]()
    
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
        
        initialDerivations = wallet.accounts.map { CoinDerivation(coin: $0.coin, derivation: $0.derivation) }
        cellModels = CoinDerivation.supportedCoinDerivations.map { coinDerivation in
            let isEnabled = initialDerivations.contains(coinDerivation)
            return CoinDerivationCellModel(coinDerivation: coinDerivation, isEnabled: isEnabled)
        }
    }
    
    @IBAction func cancelButtonTapped(_ sender: Any) {
        showAccountsList()
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        let newDerivations: [CoinDerivation] = cellModels.compactMap { model in
            if model.isEnabled {
                return model.coinDerivation
            } else {
                return nil
            }
        }
        
        if newDerivations != initialDerivations {
            do {
                try walletsManager.update(wallet: wallet, coinDerivations: newDerivations)
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
    
}

extension EditAccountsViewController: CoinDerivationCellDelegate {
    
    func didToggleCheckmark(_ sender: NSTableRowView) {
        let row = tableView.row(for: sender)
        guard row >= 0 else { return }
        toggleCoinDerivation(row: row)
    }
    
}

extension EditAccountsViewController: NSTableViewDelegate {
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? CoinDerivationCellView {
            rowView.toggle()
            toggleCoinDerivation(row: row)
        }
        return false
    }
    
}

extension EditAccountsViewController: NSTableViewDataSource {
    
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let model = cellModels[row]
        let rowView = tableView.makeViewOfType(CoinDerivationCellView.self, owner: self)
        rowView.setup(title: model.coinDerivation.title, image: Images.logo(coin: model.coinDerivation.coin), isEnabled: model.isEnabled, delegate: self)
        return rowView
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return cellModels.count
    }
    
}
