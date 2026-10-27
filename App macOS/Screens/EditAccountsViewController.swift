import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Cocoa

class EditAccountsViewController: NSViewController, NativeWalletProtectedContent {

    var walletAccess = NativeWalletAccess()
    var wallet: WalletSnapshot!
    var getBackToRect: CGRect?

    var walletsManager = ApplicationServices.shared.wallets
    private(set) var previewState: AccountPreviewState!
    private let previewAccountsPreloadThreshold = 4
    private var previewLayoutTask: Task<Void, Never>?
    private var previewPagingTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var didAppear = false
    private var isSaving = false
    private var isRetired = false
    private var acceptsManagementActions: Bool { walletAccess.isCurrent && !isRetired }

    func retireForWalletLock() {
        guard !isRetired else { return }
        isRetired = true
        previewLayoutTask?.cancel()
        previewPagingTask?.cancel()
        previewPagingTask = nil
        mutationTask?.cancel()
        previewState?.invalidate()
        previewState = nil
        wallet = nil
        getBackToRect = nil
        NotificationCenter.default.removeObserver(self)
        if isViewLoaded {
            tableView.reloadData()
            Window.clearText(in: view)
            okButton.isEnabled = false
            cancelButton.isEnabled = false
        }
    }
    
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
        guard acceptsManagementActions else { return }
        (tableView.enclosingScrollView?.verticalScroller as? WalletActivityScroller)?.accessibilityInteraction = { [weak self] in
            guard let self, !isRetired, viewIfLoaded?.window?.contentViewController === self else { return false }
            return walletAccess.beginAction()
        }
        
        okButton.title = Strings.ok
        cancelButton.title = Strings.cancel
        titleLabel.stringValue = Strings.editAccounts.replacingOccurrences(of: " ", with: "\n")
        previewState = AccountPreviewState(
            wallet: wallet,
            makeSession: { [walletsManager, walletAccess] in
                let session = try await walletAccess.requireCurrentAccess()
                return try await walletsManager.previewSession(wallet: $0, access: session)
            },
            didChange: { [weak self] in self?.previewDidChange($0) }
        )
        previewState.reset()
        guard !isRetired else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard acceptsManagementActions else { return }
        didAppear = true
        previewMoreAccountsIfNeededForCurrentViewport()
    }

    isolated deinit {
        previewLayoutTask?.cancel()
        previewPagingTask?.cancel()
        mutationTask?.cancel()
        previewState?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    @IBAction func cancelButtonTapped(_ sender: Any) {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions else { return }
        showAccountsList()
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions, !isSaving, let previewState else { return }
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
            guard let self, !Task.isCancelled, acceptsManagementActions else { return }
            do {
                let session = try walletAccess.requireCurrentAccess()
                try await walletsManager.update(wallet: wallet, enabledAccounts: newAccounts, access: session)
                guard !Task.isCancelled, acceptsManagementActions else { return }
                finishSaving()
                showAccountsList()
            } catch {
                guard !Task.isCancelled, acceptsManagementActions else { return }
                finishSaving()
                presentMessageAlert(Strings.somethingWentWrong, style: .informational)
            }
        }
    }

    private func finishSaving() {
        guard !isRetired else { return }
        isSaving = false
        updateOkButtonState()
        cancelButton.isEnabled = true
        tableView.isEnabled = true
        tableView.reloadData()
    }

    private func showAccountsList() {
        guard acceptsManagementActions else { return }
        mutationTask?.cancel()
        invalidatePreviewAccounts()
        NotificationCenter.default.removeObserver(self, name: .walletsChanged, object: nil)
        let accountsListViewController = AccountsListViewController()
        accountsListViewController.walletAccess = walletAccess
        accountsListViewController.getBackToRect = getBackToRect
        if let window = view.window?.windowController as? WalletWindowController {
            window.installProtectedContent(accountsListViewController, access: walletAccess)
        } else {
            view.window?.contentViewController = accountsListViewController
        }
    }
    
    private func toggleAccount(at row: Int) {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions, !isSaving else { return }
        previewState.toggle(at: row)
    }

    private func updateOkButtonState() {
        okButton.isEnabled = !isRetired && !isSaving && previewState?.hasEnabledAccounts == true
    }

    private func invalidatePreviewAccounts() {
        previewLayoutTask?.cancel()
        previewLayoutTask = nil
        previewPagingTask?.cancel()
        previewPagingTask = nil
        previewState?.invalidate()
    }

    private func previewDidChange(_ change: AccountPreviewState.Change) {
        guard acceptsManagementActions else {
            retireForWalletLock()
            return
        }
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
                  acceptsManagementActions,
                  previewState.activatePaging(for: generation) else { return }
            guard self.didAppear else { return }
            self.previewMoreAccountsIfNeededForCurrentViewport()
        }
    }

    private func previewMoreAccountsIfNeededForCurrentViewport() {
        guard acceptsManagementActions, let previewState else { return }
        guard shouldPreviewMoreAccountsForCurrentViewport(), !isRetired,
              self.previewState === previewState else { return }
        previewState.loadMore()
    }

    private func shouldPreviewMoreAccountsForCurrentViewport() -> Bool {
        guard !isRetired, let previewState, !previewState.accounts.isEmpty else { return false }

        tableView.layoutSubtreeIfNeeded()
        guard !isRetired, self.previewState === previewState else { return false }
        let triggerRow = max(previewState.accounts.count - previewAccountsPreloadThreshold, 0)
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        if visibleRows.length > 0, visibleRows.location + visibleRows.length - 1 >= triggerRow {
            return true
        }

        let visibleHeight = tableView.enclosingScrollView?.contentView.bounds.height ?? tableView.visibleRect.height
        return tableView.frame.height <= visibleHeight
    }

    private func schedulePreviewPaging(after row: Int) {
        guard !isRetired, let previewState,
              row >= previewState.accounts.count - previewAccountsPreloadThreshold,
              previewPagingTask == nil else { return }
        previewPagingTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            previewPagingTask = nil
            guard acceptsManagementActions, let previewState = self.previewState else { return }
            previewState.loadMore()
        }
    }

    @objc private func walletsChanged() {
        guard acceptsManagementActions else { return }
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

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        schedulePreviewPaging(after: row)
    }
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard acceptsManagementActions, !isSaving else { return false }
        if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? PreviewAccountCellView {
            rowView.toggle()
            toggleAccount(at: row)
        }
        return false
    }
    
}

extension EditAccountsViewController: NSTableViewDataSource {
    
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard !isRetired, let previewState, previewState.accounts.indices.contains(row) else { return nil }
        let account = previewState.accounts[row]
        let rowView = tableView.makeViewOfType(PreviewAccountCellView.self)
        rowView.setup(title: account.nameOrCroppedAddress(walletId: previewState.wallet.id),
                      index: account.previewDerivationIndex,
                      image: account.image,
                      isEnabled: previewState.isEnabled(account),
                      delegate: self)
        rowView.checkBox.isEnabled = !isSaving
        
        return rowView
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return isRetired ? 0 : previewState?.accounts.count ?? 0
    }
    
}
