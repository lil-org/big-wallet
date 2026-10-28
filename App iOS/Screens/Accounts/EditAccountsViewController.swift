import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import UIKit

class EditAccountsViewController: WalletAccessViewController {

    var wallet: WalletSnapshot!
    var walletsManager = ApplicationServices.shared.wallets
    var makePreviewSession: @Sendable (WalletsManager, WalletSnapshot, WalletAccessSession) async throws -> any AccountPreviewSession = {
        try await $0.previewSession(wallet: $1, access: $2)
    }
    var waitForInitialPreviewLayout: @MainActor () async -> Void = { await Task.yield() }
    private var layoutTask: Task<Void, Never>?
    private(set) var previewState: AccountPreviewState!
    private let previewAccountsPreloadThreshold = 4
    private var previewActivationTask: Task<Void, Never>?
    private var previewPreloadTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var didAppear = false
    private var isSaving = false
    private var isRetired = false
    private var previewNeedsStoreRecovery = false
    let previewRetryButton = UIButton(type: .system)
    private let previewStatusLabel = UILabel()
    private let previewStatusView = UIView()
    private var statusCenterConstraint: NSLayoutConstraint?
    private var statusBottomConstraint: NSLayoutConstraint?
    private var previewStatusInset: CGFloat = 0

    private var canEditPreview: Bool {
        !isRetired && hasCurrentWalletPresentation && walletsManager.isStoreReady && !isSaving && previewState?.canEdit == true
    }
    
    @IBOutlet weak var okButton: UIButton!
    @IBOutlet weak var tableView: UITableView! {
        didSet {
            (tableView as? WalletActivityTableView)?.accessibilityInteraction = { [weak self] in
                self?.beginWalletAction() == true
            }
            tableView.delegate = self
            tableView.dataSource = self
            tableView.registerReusableCell(type: PreviewAccountTableViewCell.self)
            let bottomOverlayHeight: CGFloat = 70
            tableView.contentInset.bottom += bottomOverlayHeight
            tableView.verticalScrollIndicatorInsets.bottom += bottomOverlayHeight
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        okButton.setTitle(Strings.ok, for: .normal)
        configureAdaptiveLargeTitle(Strings.editAccounts, tableView: tableView)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: Strings.cancel, style: .plain, target: self, action: #selector(cancelEditing))
        configurePreviewStatus()
        previewState = AccountPreviewState(
            wallet: wallet,
            makeSession: { @MainActor [weak self, walletsManager, makePreviewSession] wallet in
                guard let self else { throw WalletCredentialError.authorizationUnavailable }
                let session = try requireCurrentAccess()
                return try await makePreviewSession(walletsManager, wallet, session)
            },
            didChange: { [weak self] in self?.previewDidChange($0) }
        )
        if hasWalletAccess, walletsManager.isStoreReady { previewState.reset() }
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(storeLoadStateChanged), name: .walletsLoadStateChanged, object: walletsManager)
        updatePreviewStatus()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateAdaptiveLargeTitleLayout(Strings.editAccounts, tableView: tableView)
        updatePreviewStatusInset()
    }
    
    isolated deinit {
        previewActivationTask?.cancel()
        previewPreloadTask?.cancel()
        layoutTask?.cancel()
        mutationTask?.cancel()
        retryTask?.cancel()
        previewState?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        layoutTask?.cancel()
        layoutTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.navigationController?.navigationBar.sizeToFit()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear = true
        if !isRetired, hasWalletAccess { previewMoreAccountsIfNeededForCurrentViewport() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        layoutTask?.cancel()
        mutationTask?.cancel()

        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            isRetired = true
            retryTask?.cancel()
            NotificationCenter.default.removeObserver(self, name: .walletsChanged, object: nil)
            NotificationCenter.default.removeObserver(self, name: .walletsLoadStateChanged, object: walletsManager)
            invalidatePreviewAccounts()
        }
    }
    
    private func toggleAccountAtIndex(_ index: Int) {
        guard beginWalletAction(), canEditPreview else { return }
        previewState.toggle(at: index)
    }

    private func updateOkButtonState() {
        okButton.isEnabled = canEditPreview && previewState.hasEnabledAccounts
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        guard beginWalletAction(), canEditPreview, let previewState else { return }
        guard previewState.hasChanges else {
            closeEditor()
            return
        }
        let wallet = previewState.wallet
        let newAccounts = previewState.enabledAccounts
        isSaving = true
        updateOkButtonState()
        tableView.isUserInteractionEnabled = false
        updatePreviewStatus()
        mutationTask = Task { [weak self, walletsManager] in
            guard let self, !Task.isCancelled, hasWalletAccess else { return }
            do {
                let session = try requireCurrentAccess()
                try await walletsManager.update(wallet: wallet, enabledAccounts: newAccounts, access: session)
                guard !Task.isCancelled, !isRetired, hasWalletAccess else { return }
                finishSaving()
                closeEditor()
            } catch {
                guard !Task.isCancelled, !isRetired, hasWalletAccess else { return }
                finishSaving()
                showMessageAlert(text: Strings.somethingWentWrong)
            }
        }
    }

    private func finishSaving() {
        isSaving = false
        updateOkButtonState()
        tableView.isUserInteractionEnabled = true
        updatePreviewStatus()
    }

    private func invalidatePreviewAccounts() {
        previewActivationTask?.cancel()
        previewActivationTask = nil
        previewPreloadTask?.cancel()
        previewPreloadTask = nil
        previewState?.invalidate()
    }

    @objc private func closeEditor() {
        guard hasWalletAccess else { return }
        isRetired = true
        mutationTask?.cancel()
        retryTask?.cancel()
        NotificationCenter.default.removeObserver(self, name: .walletsChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .walletsLoadStateChanged, object: walletsManager)
        invalidatePreviewAccounts()
        let presenter = navigationController?.presentingViewController ?? presentingViewController
        (presenter ?? self).dismiss(animated: true)
    }

    @objc private func cancelEditing() {
        guard beginWalletAction() else { return }
        closeEditor()
    }

    @objc private func walletsChanged() {
        guard !isRetired, hasWalletAccess, walletsManager.isStoreReady else { return }
        let currentWallet = walletsManager.currentWallet(id: previewState.wallet.id)
        if case .close = previewState.refresh(wallet: currentWallet) {
            closeEditor()
        }
    }

    @objc private func storeLoadStateChanged() {
        guard !isRetired, hasWalletAccess, let previewState else { return }
        if walletsManager.isStoreReady {
            guard case .keepEditing = previewState.refresh(wallet: walletsManager.currentWallet(id: previewState.wallet.id)) else {
                closeEditor()
                return
            }
            if previewNeedsStoreRecovery, previewState.canRetry { previewState.retry() }
            else if previewState.status == .idle { previewState.reset() }
            previewNeedsStoreRecovery = false
        } else if case .failed = walletsManager.loadState {
            previewNeedsStoreRecovery = true
            previewActivationTask?.cancel()
            previewPreloadTask?.cancel()
            previewState.suspendForStore()
        } else if walletsManager.loadState == .loading,
                  previewState.status == .loadingInitial || previewState.status == .recovering {
            previewNeedsStoreRecovery = true
            previewState.suspendForStore()
        }
        updatePreviewStatus()
    }

    @objc func retryPreview() {
        guard !isRetired, beginWalletAction(), retryTask == nil, !isSaving else { return }
        if walletsManager.isStoreReady {
            previewState.retry()
            return
        }
        retryTask = Task { [weak self, walletsManager] in
            _ = await walletsManager.reloadFromStore()
            guard let self, !Task.isCancelled, !isRetired, hasWalletAccess else { return }
            retryTask = nil
            updatePreviewStatus()
        }
    }

    private func configurePreviewStatus() {
        previewStatusLabel.numberOfLines = 0
        previewStatusLabel.textAlignment = .center
        previewStatusLabel.font = .preferredFont(forTextStyle: .body)
        previewStatusLabel.adjustsFontForContentSizeCategory = true
        previewRetryButton.setTitle(Strings.tryAgain, for: .normal)
        previewRetryButton.accessibilityIdentifier = "account-preview-retry"
        previewRetryButton.addTarget(self, action: #selector(retryPreview), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [previewStatusLabel, previewRetryButton])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        previewStatusView.translatesAutoresizingMaskIntoConstraints = false
        previewStatusView.backgroundColor = .secondarySystemGroupedBackground
        view.addSubview(previewStatusView)
        previewStatusView.addSubview(stack)
        statusCenterConstraint = previewStatusView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        statusBottomConstraint = previewStatusView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -70)
        NSLayoutConstraint.activate([
            previewStatusView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewStatusView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewStatusView.heightAnchor.constraint(greaterThanOrEqualToConstant: 92),
            stack.topAnchor.constraint(equalTo: previewStatusView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: previewStatusView.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: previewStatusView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: previewStatusView.trailingAnchor, constant: -20),
        ])
        statusCenterConstraint?.isActive = true
        previewStatusView.isHidden = true
    }

    private func updatePreviewStatus() {
        guard !isRetired, let previewState else { return }
        updateOkButtonState()
        let storeFailed: Bool
        if case .failed = walletsManager.loadState { storeFailed = true } else { storeFailed = false }
        let failed = storeFailed || (walletsManager.isStoreReady && previewState.canRetry)
        let loading = !walletsManager.isStoreReady && !storeFailed || previewState.status == .loadingInitial || previewState.status == .recovering
        previewStatusLabel.text = failed ? Strings.failedToLoad : Strings.loading
        previewRetryButton.isHidden = !failed
        previewRetryButton.isEnabled = failed && retryTask == nil && !isSaving
        let visible = failed || loading
        previewStatusView.isHidden = !visible
        statusCenterConstraint?.isActive = false
        statusBottomConstraint?.isActive = false
        if previewState.accounts.isEmpty { statusCenterConstraint?.isActive = true }
        else { statusBottomConstraint?.isActive = true }
        updatePreviewStatusInset()
        for cell in tableView.visibleCells {
            (cell as? PreviewAccountTableViewCell)?.coinSwitch.isEnabled = canEditPreview
        }
    }

    private func updatePreviewStatusInset() {
        let inset = !previewStatusView.isHidden && previewState?.accounts.isEmpty == false
            ? previewStatusView.bounds.height : 0
        guard inset != previewStatusInset else { return }
        tableView.contentInset.bottom += inset - previewStatusInset
        tableView.verticalScrollIndicatorInsets.bottom += inset - previewStatusInset
        previewStatusInset = inset
    }

    private func previewDidChange(_ change: AccountPreviewState.Change) {
        guard !isRetired, hasWalletAccess else { return }
        updatePreviewStatus()
        switch change {
        case .reload:
            tableView.reloadData()
        case .initialPage(let generation):
            tableView.reloadData()
            enablePreviewMoreAccountsAfterCurrentLayout(for: generation)
        case .append(let range):
            tableView.insertRows(at: range.map { IndexPath(row: $0, section: 0) }, with: .none)
        case .selection, .status:
            break
        }
    }

    private func enablePreviewMoreAccountsAfterCurrentLayout(for generation: UInt64) {
        previewActivationTask?.cancel()
        let waitForLayout = waitForInitialPreviewLayout
        previewActivationTask = Task { [weak self] in
            await waitForLayout()
            guard let self, !Task.isCancelled, !isRetired, hasWalletAccess,
                  previewState.activatePaging(for: generation) else { return }
            guard self.didAppear else { return }
            self.previewMoreAccountsIfNeededForCurrentViewport()
        }
    }

    private func previewMoreAccountsIfNeededForCurrentViewport() {
        guard !isRetired, hasWalletAccess, walletsManager.isStoreReady, shouldPreviewMoreAccountsForCurrentViewport() else { return }
        previewState.loadMore()
    }

    private func scheduleMoreAccountsForDisplayedRow() {
        previewPreloadTask?.cancel()
        previewPreloadTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, !isRetired, hasWalletAccess, walletsManager.isStoreReady else { return }
            previewState.loadMore()
        }
    }

    private func shouldPreviewMoreAccountsForCurrentViewport() -> Bool {
        guard !previewState.accounts.isEmpty else { return false }

        tableView.layoutIfNeeded()
        let triggerRow = max(previewState.accounts.count - previewAccountsPreloadThreshold, 0)
        if tableView.indexPathsForVisibleRows?.contains(where: { $0.row >= triggerRow }) == true {
            return true
        }

        let visibleHeight = tableView.bounds.height - tableView.adjustedContentInset.top - tableView.adjustedContentInset.bottom
        return tableView.contentSize.height <= max(visibleHeight, 0)
    }

    override func walletAccessDidLock() {
        isRetired = true
        retryTask?.cancel()
        super.walletAccessDidLock()
        mutationTask?.cancel()
        mutationTask = nil
        layoutTask?.cancel()
        invalidatePreviewAccounts()
        okButton?.isEnabled = false
    }

}

extension EditAccountsViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if hasCurrentWalletPresentation, indexPath.row >= previewState.accounts.count - previewAccountsPreloadThreshold {
            scheduleMoreAccountsForDisplayedRow()
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard beginWalletAction(), canEditPreview else { return }
        tableView.deselectRow(at: indexPath, animated: true)
        (tableView.cellForRow(at: indexPath) as? PreviewAccountTableViewCell)?.toggle()
        toggleAccountAtIndex(indexPath.row)
    }
    
}

extension EditAccountsViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return previewState?.accounts.count ?? 0
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellOfType(PreviewAccountTableViewCell.self, for: indexPath)
        let account = previewState.accounts[indexPath.row]
        cell.setup(title: account.nameOrCroppedAddress(walletId: previewState.wallet.id),
                   image: account.image,
                   index: account.previewDerivationIndex,
                   isEnabled: previewState.isEnabled(account),
                   delegate: self)
        cell.coinSwitch.isEnabled = canEditPreview
        return cell
    }
    
}

extension EditAccountsViewController: PreviewAccountTableViewCellDelegate {
    
    func didToggleSwitch(_ sender: PreviewAccountTableViewCell) {
        if let index = tableView.indexPath(for: sender)?.row {
            toggleAccountAtIndex(index)
        }
    }
    
}
