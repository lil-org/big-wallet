// ∅ 2026 lil org

import Cocoa
import WalletCore

class EditAccountsViewController: NSViewController {
    
    var wallet: WalletContainer!
    var getBackToRect: CGRect?
    var selectAccountAction: SelectAccountAction?
    
    struct PreviewAccountCellModel {
        let account: Account
        var isEnabled: Bool
    }
    
    private let walletsManager = WalletsManager.shared
    private var cellModels = [PreviewAccountCellModel]()
    private let previewAccountsQueue = DispatchQueue(label: "org.lil.wallet.accounts", qos: .userInitiated)
    private let previewAccountsPreloadThreshold = 10
    private var page = 1
    private var requestedPreviewFor: Int?
    private var isPreviewingMoreAccounts = false
    private var lastPreviewDate = Date()
    private var toggledIndexes = Set<Int>()
    private var enabledUndiscoveredAccountKeys = Set<WalletPreviewAccountKey>()
    private var previewGeneration = 0
    private var previewCoin: CoinType? { selectAccountAction?.coinType }
    
    @IBOutlet weak var tableView: RightClickTableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
        }
    }
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var okButton: NSButton!
    @IBOutlet weak var cancelButton: NSButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        okButton.title = Strings.ok
        cancelButton.title = Strings.cancel
        titleLabel.stringValue = Strings.editAccounts.replacingOccurrences(of: " ", with: "\n")
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil)
        resetPreviewAccounts()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func appendPreviewAccounts(_ previewAccounts: [Account]) {
        let newCellModels = previewAccounts.map { account in
            let isEnabled = enabledUndiscoveredAccountKeys.remove(account.previewAccountKey) != nil
            return PreviewAccountCellModel(account: account, isEnabled: isEnabled)
        }
        cellModels.append(contentsOf: newCellModels)
        updateOkButtonState()
    }
    
    @IBAction func cancelButtonTapped(_ sender: Any) {
        showAccountsList()
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        guard !toggledIndexes.isEmpty else {
            showAccountsList()
            return
        }
        
        let remainingEnabledAccounts = wallet.accounts.filter { enabledUndiscoveredAccountKeys.contains($0.previewAccountKey) }
        let newAccounts: [Account] = (cellModels.compactMap { $0.isEnabled ? $0.account : nil }) + remainingEnabledAccounts
        do {
            try walletsManager.update(wallet: wallet, enabledAccounts: newAccounts)
            showAccountsList()
        } catch {
            Alert.showWithMessage(Strings.somethingWentWrong, style: .informational)
        }
    }
    
    private func showAccountsList() {
        previewGeneration += 1
        NotificationCenter.default.removeObserver(self, name: .walletsChanged, object: nil)
        let accountsListViewController = instantiate(AccountsListViewController.self)
        accountsListViewController.selectAccountAction = selectAccountAction
        accountsListViewController.getBackToRect = getBackToRect
        view.window?.contentViewController = accountsListViewController
    }
    
    private func toggleAccount(at row: Int) {
        cellModels[row].isEnabled.toggle()
        updateOkButtonState()
        if toggledIndexes.contains(row) {
            toggledIndexes.remove(row)
        } else {
            toggledIndexes.insert(row)
        }
    }

    private func updateOkButtonState() {
        let hasVisibleEnabledAccount = cellModels.contains(where: { $0.isEnabled })
        let hasHiddenEnabledAccount = !enabledUndiscoveredAccountKeys.isEmpty
        okButton.isEnabled = hasVisibleEnabledAccount || hasHiddenEnabledAccount
    }

    private func resetPreviewAccounts() {
        previewGeneration += 1
        page = 1
        requestedPreviewFor = nil
        isPreviewingMoreAccounts = false
        toggledIndexes.removeAll()
        cellModels.removeAll()
        enabledUndiscoveredAccountKeys = Set(wallet.accounts.map { $0.previewAccountKey })

        guard let previewAccounts = try? walletsManager.previewAccounts(wallet: wallet, page: 0, coin: previewCoin) else {
            updateOkButtonState()
            tableView.reloadData()
            return
        }

        appendPreviewAccounts(previewAccounts)
        tableView.reloadData()
    }

    @objc private func walletsChanged() {
        guard let currentWallet = walletsManager.currentWallet(id: wallet.id) else {
            showAccountsList()
            return
        }

        let previousAccountKeys = Set(wallet.accounts.map { $0.previewAccountKey })
        let currentAccountKeys = Set(currentWallet.accounts.map { $0.previewAccountKey })
        wallet = currentWallet

        guard previousAccountKeys != currentAccountKeys else {
            tableView.reloadData()
            return
        }

        if toggledIndexes.isEmpty {
            resetPreviewAccounts()
        } else {
            showAccountsList()
        }
    }
    
    private func previewMoreAccountsIfNeeded() {
        guard !isPreviewingMoreAccounts, requestedPreviewFor != cellModels.count else { return }
        requestedPreviewFor = cellModels.count
        isPreviewingMoreAccounts = true
        previewMoreAccounts()
    }
    
    private func previewMoreAccounts() {
        guard Date().timeIntervalSince(lastPreviewDate) > 0.23 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(230)) { [weak self] in
                self?.previewMoreAccounts()
            }
            return
        }
        guard let previewWallet = wallet else {
            isPreviewingMoreAccounts = false
            requestedPreviewFor = nil
            return
        }
        lastPreviewDate = Date()
        let requestedPage = page
        let generation = previewGeneration
        let requestedPreviewCoin = previewCoin
        previewAccountsQueue.async { [weak self, previewWallet, requestedPreviewCoin] in
            guard let self else { return }
            let previewAccounts = try? self.walletsManager.previewAccounts(wallet: previewWallet,
                                                                           page: requestedPage,
                                                                           coin: requestedPreviewCoin)
            DispatchQueue.main.async {
                guard self.previewGeneration == generation else { return }
                self.isPreviewingMoreAccounts = false
                guard let previewAccounts else {
                    self.requestedPreviewFor = nil
                    return
                }
                self.appendPreviewAccounts(previewAccounts)
                self.page = requestedPage + 1
                let currentCount = self.cellModels.count
                if !previewAccounts.isEmpty {
                    let range = (currentCount - previewAccounts.count)..<currentCount
                    self.tableView.insertRows(at: IndexSet(integersIn: range))
                }
            }
        }
    }
    
}

extension EditAccountsViewController: PreviewAccountCellDelegate {
    
    func didToggleCheckmark(_ sender: NSTableRowView) {
        let row = tableView.row(for: sender)
        guard row >= 0 else { return }
        toggleAccount(at: row)
    }
    
}

extension EditAccountsViewController: NSTableViewDelegate {
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? PreviewAccountCellView {
            rowView.toggle()
            toggleAccount(at: row)
        }
        return false
    }
    
}

extension EditAccountsViewController: NSTableViewDataSource {
    
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let model = cellModels[row]
        let rowView = tableView.makeViewOfType(PreviewAccountCellView.self, owner: self)
        rowView.setup(title: model.account.nameOrCroppedAddress(walletId: wallet.id), index: model.account.previewDerivationIndex, image: model.account.image, isEnabled: model.isEnabled, delegate: self)
        
        if row >= cellModels.count - previewAccountsPreloadThreshold {
            previewMoreAccountsIfNeeded()
        }
        
        return rowView
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return cellModels.count
    }
    
}
