// ∅ 2026 lil org

import UIKit

class EditAccountsViewController: UIViewController {

    var wallet: WalletSnapshot!
    private let walletsManager = WalletsManager.shared
    private var layoutTask: Task<Void, Never>?
    private var previewState: AccountPreviewState!
    private let previewAccountsPreloadThreshold = 4
    private var previewLayoutTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var didAppear = false
    private var isSaving = false
    
    @IBOutlet weak var okButton: UIButton!
    @IBOutlet weak var tableView: UITableView! {
        didSet {
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
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: Strings.cancel, style: .plain, target: self, action: #selector(dismissAnimated))
        previewState = AccountPreviewState(
            wallet: wallet,
            makePager: { [walletsManager] in walletsManager.previewAccountsPager(wallet: $0) },
            didChange: { [weak self] in self?.previewDidChange($0) }
        )
        previewState.reset()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateAdaptiveLargeTitleLayout(Strings.editAccounts, tableView: tableView)
    }
    
    isolated deinit {
        previewLayoutTask?.cancel()
        layoutTask?.cancel()
        mutationTask?.cancel()
        previewState?.invalidate()
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
        previewMoreAccountsIfNeededForCurrentViewport()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        layoutTask?.cancel()
        mutationTask?.cancel()

        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            invalidatePreviewAccounts()
        }
    }
    
    private func toggleAccountAtIndex(_ index: Int) {
        guard !isSaving else { return }
        previewState.toggle(at: index)
    }

    private func updateOkButtonState() {
        okButton.isEnabled = !isSaving && previewState.hasEnabledAccounts
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        guard !isSaving, let previewState else { return }
        guard previewState.hasChanges else {
            dismissAnimated()
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
            do {
                try await walletsManager.update(wallet: wallet, enabledAccounts: newAccounts)
                guard let self else { return }
                finishSaving()
                guard !Task.isCancelled else { return }
                dismissAnimated()
            } catch {
                guard let self else { return }
                finishSaving()
                guard !Task.isCancelled else { return }
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
            tableView.insertRows(at: range.map { IndexPath(row: $0, section: 0) }, with: .none)
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

        tableView.layoutIfNeeded()
        let triggerRow = max(previewState.accounts.count - previewAccountsPreloadThreshold, 0)
        if tableView.indexPathsForVisibleRows?.contains(where: { $0.row >= triggerRow }) == true {
            return true
        }

        let visibleHeight = tableView.bounds.height - tableView.adjustedContentInset.top - tableView.adjustedContentInset.bottom
        return tableView.contentSize.height <= max(visibleHeight, 0)
    }

}

extension EditAccountsViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row >= previewState.accounts.count - previewAccountsPreloadThreshold {
            previewState.loadMore()
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
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
