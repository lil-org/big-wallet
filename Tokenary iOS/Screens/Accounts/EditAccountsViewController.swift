// Copyright © 2022 Tokenary. All rights reserved.

import UIKit
import WalletCore

class EditAccountsViewController: UIViewController {
    
    struct PreviewAccountCellModel {
        let account: Account
        var isEnabled: Bool
    }
    
    var wallet: TokenaryWallet!
    private let walletsManager = WalletsManager.shared
    private var cellModels = [PreviewAccountCellModel]()
    private let previewAccountsQueue = DispatchQueue(label: "mac.tokenary.io.accounts", qos: .userInitiated)
    private var page = 1
    private var requestedPreviewFor: Int?
    private var lastPreviewDate = Date()
    
    @IBOutlet weak var okButton: UIButton!
    @IBOutlet weak var tableView: UITableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
            tableView.registerReusableCell(type: PreviewAccountTableViewCell.self)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.title = Strings.editAccounts
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(dismissAnimated))
        
        guard let previewAccounts = try? walletsManager.previewAccounts(wallet: wallet, page: 0) else { return }
        cellModels = previewAccounts.map { account, isEnabled in
            return PreviewAccountCellModel(account: account, isEnabled: isEnabled)
        }
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
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        let newAccounts: [Account] = cellModels.compactMap { model in
            if model.isEnabled {
                return model.account
            } else {
                return nil
            }
        }
        let accountsChanged = false // TODO: implement
        if accountsChanged {
            do {
                // TODO: update accounts
                dismissAnimated()
            } catch {
                showMessageAlert(text: Strings.somethingWentWrong)
            }
        } else {
            dismissAnimated()
        }
    }
    
    private func previewMoreAccountsIfNeeded() {
        guard requestedPreviewFor != cellModels.count else { return }
        requestedPreviewFor = cellModels.count
        previewMoreAccounts()
    }
    
    private func previewMoreAccounts() {
        guard Date().timeIntervalSince(lastPreviewDate) > 1.31 else {
            previewAccountsQueue.asyncAfter(deadline: .now() + .milliseconds(1310)) { [weak self] in
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
                let newCellModels = previewAccounts.map { account, isEnabled in
                    return PreviewAccountCellModel(account: account, isEnabled: isEnabled)
                }
                self?.cellModels.append(contentsOf: newCellModels)
                self?.page += 1
                if let currentCount = self?.cellModels.count {
                    let range = (currentCount - newCellModels.count)..<currentCount
                    self?.tableView.insertRows(at: range.map({ IndexPath(row: $0, section: 0) }), with: .fade)
                }
            }
        }
    }
    
}

extension EditAccountsViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row == cellModels.count - 1 {
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
