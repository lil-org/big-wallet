// ∅ 2026 lil org

import UIKit

class EditAccountsViewController: UIViewController {

    private struct PreviewAccountCellModel {
        let account: WalletAccount
        var isEnabled: Bool
    }

    var wallet: WalletContainer!
    var selectAccountAction: SelectAccountAction?
    private let walletsManager = WalletsManager.shared
    private var cellModels = [PreviewAccountCellModel]()
    private let previewAccountsPreloadThreshold = 4
    private var toggledIndexes = Set<Int>()
    private var enabledUndiscoveredAccountKeys = Set<WalletPreviewAccountKey>()
    private var previewPager: WalletsManager.PreviewAccountsPager?
    private var didAppear = false
    private var previewCoin: WalletCoin? { selectAccountAction?.coinType }
    
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
        navigationItem.title = Strings.editAccounts
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: Strings.cancel, style: .plain, target: self, action: #selector(dismissAnimated))
        resetPreviewAccounts()
    }
    
    private func appendPreviewAccounts(_ previewAccounts: [WalletAccount]) {
        let newCellModels = previewAccounts.map { account in
            let isEnabled = enabledUndiscoveredAccountKeys.remove(account.previewAccountKey) != nil
            return PreviewAccountCellModel(account: account, isEnabled: isEnabled)
        }
        cellModels.append(contentsOf: newCellModels)
        updateOkButtonState()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.main.async { [weak self] in
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

        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            invalidatePreviewAccounts()
        }
    }
    
    private func toggleAccountAtIndex(_ index: Int) {
        cellModels[index].isEnabled.toggle()
        updateOkButtonState()
        if toggledIndexes.contains(index) {
            toggledIndexes.remove(index)
        } else {
            toggledIndexes.insert(index)
        }
    }

    private func updateOkButtonState() {
        let hasVisibleEnabledAccount = cellModels.contains(where: { $0.isEnabled })
        let hasHiddenEnabledAccount = !enabledUndiscoveredAccountKeys.isEmpty
        okButton.isEnabled = hasVisibleEnabledAccount || hasHiddenEnabledAccount
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        guard !toggledIndexes.isEmpty else {
            dismissAnimated()
            return
        }
        let remainingEnabledAccounts = wallet.accounts.filter { enabledUndiscoveredAccountKeys.contains($0.previewAccountKey) }
        let newAccounts: [WalletAccount] = (cellModels.compactMap { $0.isEnabled ? $0.account : nil }) + remainingEnabledAccounts
        do {
            try walletsManager.update(wallet: wallet, enabledAccounts: newAccounts)
            dismissAnimated()
        } catch {
            showMessageAlert(text: Strings.somethingWentWrong)
        }
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

        tableView.layoutIfNeeded()
        let triggerRow = max(cellModels.count - previewAccountsPreloadThreshold, 0)
        if tableView.indexPathsForVisibleRows?.contains(where: { $0.row >= triggerRow }) == true {
            return true
        }

        let visibleHeight = tableView.bounds.height - tableView.adjustedContentInset.top - tableView.adjustedContentInset.bottom
        return tableView.contentSize.height <= max(visibleHeight, 0)
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
                self.tableView.insertRows(at: range.map({ IndexPath(row: $0, section: 0) }), with: .none)
            }
        }
    }
    
}

extension EditAccountsViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row >= cellModels.count - previewAccountsPreloadThreshold {
            previewMoreAccountsIfNeeded()
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
        return cellModels.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellOfType(PreviewAccountTableViewCell.self, for: indexPath)
        let model = cellModels[indexPath.row]
        cell.setup(title: model.account.nameOrCroppedAddress(walletId: wallet.id),
                   image: model.account.image,
                   index: model.account.previewDerivationIndex,
                   isEnabled: model.isEnabled,
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
