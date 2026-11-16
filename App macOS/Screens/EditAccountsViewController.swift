import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Cocoa

class EditAccountsViewController: NSViewController, NativeWalletProtectedContent {

    let walletAccess: NativeWalletAccess

    init?(coder: NSCoder, access: NativeWalletAccess) {
        walletAccess = access
        super.init(coder: coder)
    }

    required init?(coder: NSCoder) { return nil }

    static func with(access: NativeWalletAccess) -> EditAccountsViewController {
        instantiate(EditAccountsViewController.self) { EditAccountsViewController(coder: $0, access: access) }
    }
    var wallet: WalletSnapshot!
    var getBackToRect: CGRect?

    var walletsManager = ApplicationServices.shared.wallets
    var makePreviewSession: @Sendable (WalletsManager, WalletSnapshot, WalletAccessSession) async throws -> any AccountPreviewSession = {
        try await $0.previewSession(wallet: $1, access: $2)
    }
    var waitForPreviewLayout: @MainActor () async -> Void = { await Task.yield() }
    private(set) var previewState: AccountPreviewState!
    private let previewAccountsPreloadThreshold = 4
    private var didAppear = false
    private var isRetired = false
    private var hasCurrentPresentation: Bool { walletAccess.hasCurrentPresentation && !isRetired }
    private var canEditPreview: Bool {
        hasCurrentPresentation && previewState?.canEdit == true
    }
    let previewRetryButton = NSButton(title: "", target: nil, action: nil)
    private let previewStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let previewStatusView = NSBox()
    private var statusCenterConstraint: NSLayoutConstraint?
    private var statusBottomConstraint: NSLayoutConstraint?
    private var originalBottomInset: CGFloat = 0

    private func validateManagementActions() -> Bool { walletAccess.validateCurrentAccess() && hasCurrentPresentation }

    func retire() {
        retireEditor()
    }

    private func retireEditor() {
        guard !isRetired else { return }
        isRetired = true
        invalidatePreviewAccounts()
        previewState = nil
        wallet = nil
        getBackToRect = nil
        NotificationCenter.default.removeObserver(self)
        if isViewLoaded {
            tableView.reloadData()
            Window.clearText(in: view)
            okButton.isEnabled = false
            cancelButton.isEnabled = false
            previewStatusView.isHidden = true
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
        guard validateManagementActions() else { return }
        (tableView.enclosingScrollView?.verticalScroller as? WalletActivityScroller)?.accessibilityInteraction = { [weak self] in
            guard let self, !isRetired, viewIfLoaded?.window?.contentViewController === self else { return false }
            return walletAccess.beginAction()
        }
        
        okButton.title = Strings.ok
        cancelButton.title = Strings.cancel
        titleLabel.stringValue = Strings.editAccounts.replacingOccurrences(of: " ", with: "\n")
        configurePreviewStatus()
        previewState = AccountPreviewState(
            wallet: wallet,
            makeSession: { [walletsManager, walletAccess, makePreviewSession] in
                let session = try await walletAccess.requireCurrentAccess()
                return try await makePreviewSession(walletsManager, $0, session)
            },
            waitForLayout: waitForPreviewLayout,
            didChange: { [weak self] in self?.previewDidChange($0) }
        )
        reconcileStore()
        guard !isRetired else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(storeLoadStateChanged), name: .walletsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(storeLoadStateChanged), name: .walletsLoadStateChanged, object: walletsManager)
        updatePreviewStatus()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard validateManagementActions() else { return }
        didAppear = true
        requestPreviewPaging()
    }

    isolated deinit {
        previewState?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    @IBAction func cancelButtonTapped(_ sender: Any) {
        guard hasCurrentPresentation, walletAccess.beginAction() else { return }
        showAccountsList()
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        guard hasCurrentPresentation, walletAccess.beginAction() else { return }
        previewState?.save { [walletsManager, walletAccess] wallet, accounts in
            let session = try walletAccess.requireCurrentAccess()
            try await walletsManager.update(wallet: wallet, enabledAccounts: accounts, access: session)
        }
    }

    private func showAccountsList() {
        guard validateManagementActions() else { return }
        guard let window = viewIfLoaded?.window?.windowController as? WalletWindowController else { return }
        let accountsListViewController = AccountsListViewController(access: walletAccess)
        accountsListViewController.getBackToRect = getBackToRect
        window.installProtectedContent(accountsListViewController, access: walletAccess)
    }
    
    private func toggleAccount(at row: Int) {
        guard hasCurrentPresentation, walletAccess.beginAction() else { return }
        guard canEditPreview else { return }
        previewState.toggle(at: row)
    }

    private func updateOkButtonState() {
        okButton.isEnabled = hasCurrentPresentation && previewState?.canSave == true
    }

    private func invalidatePreviewAccounts() {
        previewState?.invalidate()
    }

    private func previewDidChange(_ change: AccountPreviewState.Change) {
        guard validateManagementActions() else {
            retire()
            return
        }
        updatePreviewStatus()
        switch change {
        case .reload:
            tableView.reloadData()
        case .initialPage:
            tableView.reloadData()
            requestPreviewPaging()
        case .append(let range):
            tableView.insertRows(at: IndexSet(integersIn: range))
            requestPreviewPaging()
        case .selection, .status:
            break
        case .close:
            showAccountsList()
        case .saveFailed:
            presentMessageAlert(Strings.somethingWentWrong, style: .informational)
        }
    }

    private func requestPreviewPaging() {
        guard hasCurrentPresentation else { return }
        previewState?.requestPaging { [weak self] in
            guard let self, didAppear, validateManagementActions() else { return false }
            return shouldPreviewMoreAccountsForCurrentViewport()
        }
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
              row >= previewState.accounts.count - previewAccountsPreloadThreshold else { return }
        requestPreviewPaging()
    }

    @objc private func storeLoadStateChanged() {
        reconcileStore()
    }

    private func reconcileStore() {
        guard validateManagementActions(), let previewState else { return }
        previewState.reconcileStore(
            loadState: walletsManager.loadState,
            isReady: walletsManager.isStoreReady,
            wallet: walletsManager.currentWallet(id: previewState.wallet.id)
        )
    }

    @objc func retryPreview() {
        guard hasCurrentPresentation, walletAccess.beginAction() else { return }
        guard validateManagementActions() else { return }
        previewState?.retry { [walletsManager] in
            _ = await walletsManager.reloadFromStore()
        }
    }

    private func configurePreviewStatus() {
        guard let scrollView = tableView.enclosingScrollView else { return }
        originalBottomInset = scrollView.contentInsets.bottom
        previewStatusView.boxType = .custom
        previewStatusView.borderType = .noBorder
        previewStatusView.fillColor = .windowBackgroundColor
        previewStatusView.contentViewMargins = NSSize(width: 12, height: 8)
        previewStatusView.translatesAutoresizingMaskIntoConstraints = false
        previewStatusLabel.alignment = .center
        previewStatusLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        previewRetryButton.title = Strings.tryAgain
        previewRetryButton.target = self
        previewRetryButton.action = #selector(retryPreview)
        previewRetryButton.setAccessibilityIdentifier("account-preview-retry")
        let stack = NSStackView(views: [previewStatusLabel, previewRetryButton])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewStatusView)
        let container = previewStatusView.contentView!
        container.addSubview(stack)
        statusCenterConstraint = previewStatusView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        statusBottomConstraint = previewStatusView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        NSLayoutConstraint.activate([
            previewStatusView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            previewStatusView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            previewStatusView.heightAnchor.constraint(equalToConstant: 92),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        previewStatusView.isHidden = true
    }

    private func updatePreviewStatus() {
        guard !isRetired, let previewState else { return }
        updateOkButtonState()
        let failed = previewState.loadPresentation == .failed
        previewStatusLabel.stringValue = failed ? Strings.failedToLoad : Strings.loading
        previewRetryButton.isHidden = !failed
        previewRetryButton.isEnabled = previewState.canRetry
        previewStatusView.isHidden = previewState.loadPresentation == .hidden
        tableView.isEnabled = !previewState.isSaving
        statusCenterConstraint?.isActive = false
        statusBottomConstraint?.isActive = false
        if previewState.accounts.isEmpty { statusCenterConstraint?.isActive = true }
        else { statusBottomConstraint?.isActive = true }
        if let scrollView = tableView.enclosingScrollView {
            var insets = scrollView.contentInsets
            insets.bottom = originalBottomInset + (!previewStatusView.isHidden && !previewState.accounts.isEmpty ? 92 : 0)
            scrollView.contentInsets = insets
        }
        tableView.enumerateAvailableRowViews { [self] row, _ in
            (row as? PreviewAccountCellView)?.checkBox.isEnabled = canEditPreview
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
        guard hasCurrentPresentation, walletAccess.beginAction(), canEditPreview else { return false }
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
        rowView.checkBox.isEnabled = canEditPreview
        
        return rowView
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return isRetired ? 0 : previewState?.accounts.count ?? 0
    }
    
}
