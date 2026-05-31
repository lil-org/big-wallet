// ∅ 2026 lil org

import Cocoa

class EditAccountsViewController: NSViewController {

    private struct PreviewAccountCellModel {
        let account: WalletAccount
        var isEnabled: Bool
    }
    
    var wallet: WalletContainer!
    var getBackToRect: CGRect?
    var selectAccountAction: SelectAccountAction?

    private let walletsManager = WalletsManager.shared
    private var cellModels = [PreviewAccountCellModel]()
    private let previewAccountsPreloadThreshold = 4
    private var toggledIndexes = Set<Int>()
    private var enabledUndiscoveredAccountKeys = Set<WalletPreviewAccountKey>()
    private var previewPager: WalletsManager.PreviewAccountsPager?
    private var didAppear = false
    private var previewCoin: WalletCoin? { selectAccountAction?.coinType }
    
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

    override func viewDidAppear() {
        super.viewDidAppear()
        didAppear = true
        previewMoreAccountsIfNeededForCurrentViewport()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func appendPreviewAccounts(_ previewAccounts: [WalletAccount]) {
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
        let newAccounts: [WalletAccount] = (cellModels.compactMap { $0.isEnabled ? $0.account : nil }) + remainingEnabledAccounts
        do {
            try walletsManager.update(wallet: wallet, enabledAccounts: newAccounts)
            showAccountsList()
        } catch {
            Alert.showWithMessage(Strings.somethingWentWrong, style: .informational)
        }
    }
    
    private func showAccountsList() {
        invalidatePreviewAccounts()
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
        previewPager?.invalidate()
        let previewPager = walletsManager.previewAccountsPager(wallet: wallet, coin: previewCoin)
        self.previewPager = previewPager
        toggledIndexes.removeAll()
        cellModels.removeAll()
        enabledUndiscoveredAccountKeys = Set(wallet.accounts.map { $0.previewAccountKey })
        updateOkButtonState()
        tableView.reloadData()
        loadInitialPreviewAccounts(with: previewPager)
    }

    private func invalidatePreviewAccounts() {
        previewPager?.invalidate()
        previewPager = nil
    }

    private func loadInitialPreviewAccounts(with previewPager: WalletsManager.PreviewAccountsPager) {
        previewPager.reset { [weak self, weak previewPager] previewAccounts in
            guard let self,
                  let previewPager,
                  self.previewPager === previewPager
            else { return }

            guard let previewAccounts else {
                self.updateOkButtonState()
                return
            }

            self.appendPreviewAccounts(previewAccounts)
            self.tableView.reloadData()
            self.enablePreviewMoreAccountsAfterCurrentLayout(for: previewPager)
        }
    }

    private func enablePreviewMoreAccountsAfterCurrentLayout(for previewPager: WalletsManager.PreviewAccountsPager) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.previewPager === previewPager else { return }
            previewPager.enablePaging()
            guard self.didAppear else { return }
            self.previewMoreAccountsIfNeededForCurrentViewport()
        }
    }

    private func previewMoreAccountsIfNeededForCurrentViewport() {
        guard shouldPreviewMoreAccountsForCurrentViewport() else { return }
        previewMoreAccountsIfNeeded()
    }

    private func shouldPreviewMoreAccountsForCurrentViewport() -> Bool {
        guard !cellModels.isEmpty else { return false }

        tableView.layoutSubtreeIfNeeded()
        let triggerRow = max(cellModels.count - previewAccountsPreloadThreshold, 0)
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        if visibleRows.length > 0, visibleRows.location + visibleRows.length - 1 >= triggerRow {
            return true
        }

        let visibleHeight = tableView.enclosingScrollView?.contentView.bounds.height ?? tableView.visibleRect.height
        return tableView.frame.height <= visibleHeight
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
        guard let previewPager else { return }
        previewPager.previewMoreIfNeeded { [weak self, weak previewPager] previewAccounts, range in
            guard let self,
                  let previewPager,
                  self.previewPager === previewPager
            else { return }

            self.appendPreviewAccounts(previewAccounts)
            if !previewAccounts.isEmpty {
                self.tableView.insertRows(at: IndexSet(integersIn: range))
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
        rowView.setup(title: model.account.nameOrCroppedAddress(walletId: wallet.id),
                      index: model.account.previewDerivationIndex,
                      image: model.account.image,
                      isEnabled: model.isEnabled,
                      delegate: self)
        
        if row >= cellModels.count - previewAccountsPreloadThreshold {
            previewMoreAccountsIfNeeded()
        }
        
        return rowView
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return cellModels.count
    }
    
}
