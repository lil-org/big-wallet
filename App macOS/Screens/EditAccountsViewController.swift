// ∅ 2026 lil org

import Cocoa

class EditAccountsViewController: NSViewController {

    var wallet: WalletSnapshot!
    var getBackToRect: CGRect?

    private let walletsManager = WalletsManager.shared
    private var previewState: AccountPreviewState!
    private let previewAccountsPreloadThreshold = 4
    private var previewLayoutTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var didAppear = false
    private var isSaving = false
    
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
        previewState = AccountPreviewState(
            wallet: wallet,
            makeSession: { [repository = walletsManager.repository] in try await repository.previewSession(wallet: $0) },
            didChange: { [weak self] in self?.previewDidChange($0) }
        )
        previewState.reset()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        didAppear = true
        previewMoreAccountsIfNeededForCurrentViewport()
    }

    isolated deinit {
        previewLayoutTask?.cancel()
        mutationTask?.cancel()
        previewState?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    @IBAction func cancelButtonTapped(_ sender: Any) {
        showAccountsList()
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        guard !isSaving, let previewState else { return }
        guard previewState.hasChanges else {
            showAccountsList()
            return
        }
        
        let wallet = previewState.wallet
        let newAccounts = previewState.enabledAccounts
        isSaving = true
        updateOkButtonState()
        cancelButton.isEnabled = false
        tableView.isEnabled = false
        tableView.reloadData()
        mutationTask = Task { [weak self, walletsManager] in
            do {
                try await walletsManager.update(wallet: wallet, enabledAccounts: newAccounts)
                guard let self else { return }
                finishSaving()
                guard !Task.isCancelled else { return }
                showAccountsList()
            } catch {
                guard let self else { return }
                finishSaving()
                guard !Task.isCancelled else { return }
                presentMessageAlert(Strings.somethingWentWrong, style: .informational)
            }
        }
    }

    private func finishSaving() {
        isSaving = false
        updateOkButtonState()
        cancelButton.isEnabled = true
        tableView.isEnabled = true
        tableView.reloadData()
    }

    private func showAccountsList() {
        mutationTask?.cancel()
        invalidatePreviewAccounts()
        NotificationCenter.default.removeObserver(self, name: .walletsChanged, object: nil)
        let accountsListViewController = AccountsListViewController()
        accountsListViewController.getBackToRect = getBackToRect
        view.window?.contentViewController = accountsListViewController
    }
    
    private func toggleAccount(at row: Int) {
        guard !isSaving else { return }
        previewState.toggle(at: row)
    }

    private func updateOkButtonState() {
        okButton.isEnabled = !isSaving && previewState.hasEnabledAccounts
    }

    private func invalidatePreviewAccounts() {
        previewLayoutTask?.cancel()
        previewLayoutTask = nil
        previewState.invalidate()
    }

    private func previewDidChange(_ change: AccountPreviewState.Change) {
        updateOkButtonState()
        switch change {
        case .reload:
            tableView.reloadData()
        case .initialPage(let generation):
            tableView.reloadData()
            enablePreviewMoreAccountsAfterCurrentLayout(for: generation)
        case .append(let range):
            tableView.insertRows(at: IndexSet(integersIn: range))
        case .selection:
            break
        }
    }

    private func enablePreviewMoreAccountsAfterCurrentLayout(for generation: UInt64) {
        previewLayoutTask?.cancel()
        previewLayoutTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled,
                  previewState.activatePaging(for: generation) else { return }
            guard self.didAppear else { return }
            self.previewMoreAccountsIfNeededForCurrentViewport()
        }
    }

    private func previewMoreAccountsIfNeededForCurrentViewport() {
        guard shouldPreviewMoreAccountsForCurrentViewport() else { return }
        previewState.loadMore()
    }

    private func shouldPreviewMoreAccountsForCurrentViewport() -> Bool {
        guard !previewState.accounts.isEmpty else { return false }

        tableView.layoutSubtreeIfNeeded()
        let triggerRow = max(previewState.accounts.count - previewAccountsPreloadThreshold, 0)
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        if visibleRows.length > 0, visibleRows.location + visibleRows.length - 1 >= triggerRow {
            return true
        }

        let visibleHeight = tableView.enclosingScrollView?.contentView.bounds.height ?? tableView.visibleRect.height
        return tableView.frame.height <= visibleHeight
    }

    @objc private func walletsChanged() {
        let currentWallet = walletsManager.currentWallet(id: previewState.wallet.id)
        if case .close = previewState.refresh(wallet: currentWallet) {
            showAccountsList()
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
        guard !isSaving else { return false }
        if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? PreviewAccountCellView {
            rowView.toggle()
            toggleAccount(at: row)
        }
        return false
    }
    
}

extension EditAccountsViewController: NSTableViewDataSource {
    
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let account = previewState.accounts[row]
        let rowView = tableView.makeViewOfType(PreviewAccountCellView.self)
        rowView.setup(title: account.nameOrCroppedAddress(walletId: previewState.wallet.id),
                      index: account.previewDerivationIndex,
                      image: account.image,
                      isEnabled: previewState.isEnabled(account),
                      delegate: self)
        rowView.checkBox.isEnabled = !isSaving
        
        if row >= previewState.accounts.count - previewAccountsPreloadThreshold {
            previewState.loadMore()
        }
        
        return rowView
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return previewState?.accounts.count ?? 0
    }
    
}
