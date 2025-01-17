// ∅ 2025 lil org

import UIKit
import WalletCore

class EditAccountsViewController: UIViewController {
    
    struct PreviewAccountCellModel {
        let account: Account
        var isEnabled: Bool
    }
    
    var wallet: WalletContainer!
    private let walletsManager = WalletsManager.shared
    private var cellModels = [PreviewAccountCellModel]()
    private let previewAccountsQueue = DispatchQueue(label: "org.lil.wallet.accounts", qos: .userInitiated)
    private var page = 1
    private var requestedPreviewFor: Int?
    private var lastPreviewDate = Date()
    private var toggledIndexes = Set<Int>()
    private var enabledUndiscoveredAccounts = [Account]()
    
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
        enabledUndiscoveredAccounts = wallet.accounts
        guard let previewAccounts = try? walletsManager.previewAccounts(wallet: wallet, page: 0) else { return }
        appendPreviewAccounts(previewAccounts)
    }
    
    private func appendPreviewAccounts(_ previewAccounts: [Account]) {
        let newCellModels = previewAccounts.map { account in
            let isEnabled = enabledUndiscoveredAccounts.first?.derivationPath == account.derivationPath
            if isEnabled {
                enabledUndiscoveredAccounts.removeFirst()
            }
            return PreviewAccountCellModel(account: account, isEnabled: isEnabled)
        }
        cellModels.append(contentsOf: newCellModels)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.main.async { [weak self] in
            self?.navigationController?.navigationBar.sizeToFit()
        }
    }
    
    private func toggleAccountAtIndex(_ index: Int) {
        cellModels[index].isEnabled.toggle()
        okButton.isEnabled = cellModels.contains(where: { $0.isEnabled })
        if toggledIndexes.contains(index) {
            toggledIndexes.remove(index)
        } else {
            toggledIndexes.insert(index)
        }
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        guard !toggledIndexes.isEmpty else {
            dismissAnimated()
            return
        }
        let newAccounts: [Account] = (cellModels.compactMap { $0.isEnabled ? $0.account : nil }) + enabledUndiscoveredAccounts
        do {
            try walletsManager.update(wallet: wallet, enabledAccounts: newAccounts)
            dismissAnimated()
        } catch {
            showMessageAlert(text: Strings.somethingWentWrong)
        }
    }
    
    private func previewMoreAccountsIfNeeded() {
        guard requestedPreviewFor != cellModels.count else { return }
        requestedPreviewFor = cellModels.count
        previewMoreAccounts()
    }
    
    private func previewMoreAccounts() {
        guard Date().timeIntervalSince(lastPreviewDate) > 0.23 else {
            previewAccountsQueue.asyncAfter(deadline: .now() + .milliseconds(230)) { [weak self] in
                self?.previewMoreAccounts()
            }
            return
        }
        lastPreviewDate = Date()
        previewAccountsQueue.async { [weak self] in
            guard let wallet = self?.wallet,
                  let page = self?.page,
                  let previewAccounts = try? self?.walletsManager.previewAccounts(wallet: wallet, page: page) else { return }
            DispatchQueue.main.async {
                self?.appendPreviewAccounts(previewAccounts)
                self?.page += 1
                if let currentCount = self?.cellModels.count {
                    let range = (currentCount - previewAccounts.count)..<currentCount
                    self?.tableView.insertRows(at: range.map({ IndexPath(row: $0, section: 0) }), with: .fade)
                }
            }
        }
    }
    
}

extension EditAccountsViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row >= cellModels.count - 20 {
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
        // TODO: get account name
        cell.setup(title: model.account.croppedAddress, image: model.account.image, index: indexPath.row, isEnabled: model.isEnabled, delegate: self)
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
