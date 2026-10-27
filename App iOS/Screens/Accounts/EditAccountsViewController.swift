import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import UIKit

class EditAccountsViewController: WalletAccessViewController {

    var wallet: WalletSnapshot!
    var walletsManager = ApplicationServices.shared.wallets
    var waitForInitialPreviewLayout: @MainActor () async -> Void = { await Task.yield() }
    private var layoutTask: Task<Void, Never>?
    private(set) var previewState: AccountPreviewState!
    private let previewAccountsPreloadThreshold = 4
    private var previewActivationTask: Task<Void, Never>?
    private var previewPreloadTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var didAppear = false
    private var isSaving = false
    
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
        previewState = AccountPreviewState(
            wallet: wallet,
            makeSession: { @MainActor [weak self, walletsManager] wallet in
                guard let self else { throw WalletCredentialError.authorizationUnavailable }
                try requireCurrentCredentials()
                return try await walletsManager.previewSession(wallet: wallet)
            },
            didChange: { [weak self] in self?.previewDidChange($0) }
        )
        if hasWalletAccess { previewState.reset() }
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateAdaptiveLargeTitleLayout(Strings.editAccounts, tableView: tableView)
    }
    
    isolated deinit {
        previewActivationTask?.cancel()
        previewPreloadTask?.cancel()
        layoutTask?.cancel()
        mutationTask?.cancel()
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
        if hasWalletAccess { previewMoreAccountsIfNeededForCurrentViewport() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        layoutTask?.cancel()
        mutationTask?.cancel()

        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            NotificationCenter.default.removeObserver(self, name: .walletsChanged, object: nil)
            invalidatePreviewAccounts()
        }
    }
    
    private func toggleAccountAtIndex(_ index: Int) {
        guard beginWalletAction(), !isSaving else { return }
        previewState.toggle(at: index)
    }

    private func updateOkButtonState() {
        okButton.isEnabled = hasCurrentWalletPresentation && !isSaving && previewState.hasEnabledAccounts
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        guard beginWalletAction(), !isSaving, let previewState else { return }
        guard previewState.hasChanges else {
            closeEditor()
            return
        }
        let wallet = previewState.wallet
        let newAccounts = previewState.enabledAccounts
        isSaving = true
        updateOkButtonState()
        view.isUserInteractionEnabled = false
        isModalInPresentation = true
        navigationItem.leftBarButtonItem?.isEnabled = false
        mutationTask = Task { [weak self, walletsManager] in
            guard let self, !Task.isCancelled, hasWalletAccess else { return }
            do {
                try requireCurrentCredentials()
                try await walletsManager.update(wallet: wallet, enabledAccounts: newAccounts)
                guard !Task.isCancelled, hasWalletAccess else { return }
                finishSaving()
                closeEditor()
            } catch {
                guard !Task.isCancelled, hasWalletAccess else { return }
                finishSaving()
                showMessageAlert(text: Strings.somethingWentWrong)
            }
        }
    }

    private func finishSaving() {
        isSaving = false
        updateOkButtonState()
        view.isUserInteractionEnabled = true
        isModalInPresentation = false
        navigationItem.leftBarButtonItem?.isEnabled = true
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
        mutationTask?.cancel()
        NotificationCenter.default.removeObserver(self, name: .walletsChanged, object: nil)
        invalidatePreviewAccounts()
        let presenter = navigationController?.presentingViewController ?? presentingViewController
        (presenter ?? self).dismiss(animated: true)
    }

    @objc private func cancelEditing() {
        guard beginWalletAction() else { return }
        closeEditor()
    }

    @objc private func walletsChanged() {
        guard hasWalletAccess else { return }
        let currentWallet = walletsManager.currentWallet(id: previewState.wallet.id)
        if case .close = previewState.refresh(wallet: currentWallet) {
            closeEditor()
        }
    }

    private func previewDidChange(_ change: AccountPreviewState.Change) {
        guard hasWalletAccess else { return }
        updateOkButtonState()
        switch change {
        case .reload:
            tableView.reloadData()
        case .initialPage(let generation):
            tableView.reloadData()
            enablePreviewMoreAccountsAfterCurrentLayout(for: generation)
        case .append(let range):
            tableView.insertRows(at: range.map { IndexPath(row: $0, section: 0) }, with: .none)
        case .selection:
            break
        }
    }

    private func enablePreviewMoreAccountsAfterCurrentLayout(for generation: UInt64) {
        previewActivationTask?.cancel()
        let waitForLayout = waitForInitialPreviewLayout
        previewActivationTask = Task { [weak self] in
            await waitForLayout()
            guard let self, !Task.isCancelled, hasWalletAccess,
                  previewState.activatePaging(for: generation) else { return }
            guard self.didAppear else { return }
            self.previewMoreAccountsIfNeededForCurrentViewport()
        }
    }

    private func previewMoreAccountsIfNeededForCurrentViewport() {
        guard hasWalletAccess, shouldPreviewMoreAccountsForCurrentViewport() else { return }
        previewState.loadMore()
    }

    private func scheduleMoreAccountsForDisplayedRow() {
        previewPreloadTask?.cancel()
        previewPreloadTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, hasWalletAccess else { return }
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
        guard beginWalletAction() else { return }
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
