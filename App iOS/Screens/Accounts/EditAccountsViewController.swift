// ∅ 2026 lil org

import UIKit
import WalletCore

class EditAccountsViewController: UIViewController {
    
    struct PreviewAccountCellModel {
        let account: Account
        var isEnabled: Bool
    }
    
    var wallet: WalletContainer!
    var selectAccountAction: SelectAccountAction?
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
    private var previewCoin: CoinType? { selectAccountAction?.coinType }
    
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
        enabledUndiscoveredAccountKeys = Set(wallet.accounts.map { $0.previewAccountKey })
        guard let previewAccounts = try? walletsManager.previewAccounts(wallet: wallet, page: 0, coin: previewCoin) else { return }
        appendPreviewAccounts(previewAccounts)
        tableView.reloadData()
    }
    
    private func appendPreviewAccounts(_ previewAccounts: [Account]) {
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
        let newAccounts: [Account] = (cellModels.compactMap { $0.isEnabled ? $0.account : nil }) + remainingEnabledAccounts
        do {
            try walletsManager.update(wallet: wallet, enabledAccounts: newAccounts)
            dismissAnimated()
        } catch {
            showMessageAlert(text: Strings.somethingWentWrong)
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
        lastPreviewDate = Date()
        let requestedPage = page
        previewAccountsQueue.async { [weak self] in
            guard let self else { return }
            let previewAccounts = try? self.walletsManager.previewAccounts(wallet: self.wallet,
                                                                           page: requestedPage,
                                                                           coin: self.previewCoin)
            DispatchQueue.main.async {
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
                    self.tableView.insertRows(at: range.map({ IndexPath(row: $0, section: 0) }), with: .fade)
                }
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
        cell.setup(title: model.account.nameOrCroppedAddress(walletId: wallet.id), image: model.account.image, index: model.account.previewDerivationIndex, isEnabled: model.isEnabled, delegate: self)
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
