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
        
        guard let previewAccounts = try? walletsManager.previewAccounts(wallet: wallet) else { return }
        cellModels = previewAccounts.map { account in
            let isEnabled = false // TODO: implement
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
    
}

extension EditAccountsViewController: UITableViewDelegate {
    
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
