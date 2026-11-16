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
    var waitForPreviewLayout: @MainActor () async -> Void = { await Task.yield() }
    private var layoutTask: Task<Void, Never>?
    private(set) var previewState: AccountPreviewState!
    private let previewAccountsPreloadThreshold = 4
    private var didAppear = false
    private var isRetired = false
    let previewRetryButton = UIButton(type: .system)
    private let previewStatusLabel = UILabel()
    private let previewStatusView = UIView()
    private var statusCenterConstraint: NSLayoutConstraint?
    private var statusBottomConstraint: NSLayoutConstraint?
    private var previewStatusInset: CGFloat = 0

    private var canEditPreview: Bool {
        !isRetired && hasCurrentWalletPresentation && previewState?.canEdit == true
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
            waitForLayout: waitForPreviewLayout,
            didChange: { [weak self] in self?.previewDidChange($0) }
        )
        reconcileStore()
        guard !isRetired else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(storeLoadStateChanged), name: .walletsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(storeLoadStateChanged), name: .walletsLoadStateChanged, object: walletsManager)
        updatePreviewStatus()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateAdaptiveLargeTitleLayout(Strings.editAccounts, tableView: tableView)
        updatePreviewStatusInset()
    }
    
    isolated deinit {
        layoutTask?.cancel()
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
        requestPreviewPaging()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        layoutTask?.cancel()
        previewState?.cancelSave()

        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            isRetired = true
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
        okButton.isEnabled = !isRetired && hasCurrentWalletPresentation && previewState?.canSave == true
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        guard !isRetired, beginWalletAction(), let previewState else { return }
        previewState.save { [weak self, walletsManager] wallet, accounts in
            guard let session = try self?.requireCurrentAccess() else {
                throw WalletCredentialError.authorizationUnavailable
            }
            try await walletsManager.update(wallet: wallet, enabledAccounts: accounts, access: session)
        }
    }

    private func invalidatePreviewAccounts() {
        previewState?.invalidate()
    }

    @objc private func closeEditor() {
        guard validateCurrentAccess() else { return }
        isRetired = true
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

    @objc private func storeLoadStateChanged() {
        reconcileStore()
    }

    private func reconcileStore() {
        guard !isRetired, validateCurrentAccess(), let previewState else { return }
        previewState.reconcileStore(
            loadState: walletsManager.loadState,
            isReady: walletsManager.isStoreReady,
            wallet: walletsManager.currentWallet(id: previewState.wallet.id)
        )
    }

    @objc func retryPreview() {
        guard !isRetired, beginWalletAction() else { return }
        previewState?.retry { [walletsManager] in
            _ = await walletsManager.reloadFromStore()
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
        let failed = previewState.loadPresentation == .failed
        previewStatusLabel.text = failed ? Strings.failedToLoad : Strings.loading
        previewRetryButton.isHidden = !failed
        previewRetryButton.isEnabled = previewState.canRetry
        previewStatusView.isHidden = previewState.loadPresentation == .hidden
        tableView.isUserInteractionEnabled = !previewState.isSaving
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
        guard !isRetired, validateCurrentAccess() else { return }
        updatePreviewStatus()
        switch change {
        case .reload:
            tableView.reloadData()
        case .initialPage:
            tableView.reloadData()
            requestPreviewPaging()
        case .append(let range):
            tableView.insertRows(at: range.map { IndexPath(row: $0, section: 0) }, with: .none)
            requestPreviewPaging()
        case .selection, .status:
            break
        case .close:
            closeEditor()
        case .saveFailed:
            showMessageAlert(text: Strings.somethingWentWrong)
        }
    }

    private func requestPreviewPaging() {
        guard !isRetired, hasCurrentWalletPresentation else { return }
        previewState?.requestPaging { [weak self] in
            guard let self, !isRetired, didAppear, validateCurrentAccess() else { return false }
            return shouldPreviewMoreAccountsForCurrentViewport()
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
        super.walletAccessDidLock()
        layoutTask?.cancel()
        invalidatePreviewAccounts()
        okButton?.isEnabled = false
    }

}

extension EditAccountsViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if hasCurrentWalletPresentation, indexPath.row >= previewState.accounts.count - previewAccountsPreloadThreshold {
            requestPreviewPaging()
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
