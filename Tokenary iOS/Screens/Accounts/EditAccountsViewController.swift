// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

class EditAccountsViewController: UIViewController {
    
    struct CoinDerivationCellModel {
        let coinDerivation: CoinDerivation
        var isEnabled: Bool
    }
    
    var wallet: TokenaryWallet!
    private let walletsManager = WalletsManager.shared
    private var initialDerivations = [CoinDerivation]()
    private var cellModels = [CoinDerivationCellModel]()
    
    @IBOutlet weak var okButton: UIButton!
    @IBOutlet weak var tableView: UITableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
            tableView.registerReusableCell(type: CoinDerivationTableViewCell.self)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.title = Strings.editAccounts
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(dismissAnimated))
        
        initialDerivations = wallet.accounts.map { CoinDerivation(coin: $0.coin, derivation: $0.derivation) }
        cellModels = CoinDerivation.supportedCoinDerivations.map { coinDerivation in
            let isEnabled = initialDerivations.contains(coinDerivation)
            return CoinDerivationCellModel(coinDerivation: coinDerivation, isEnabled: isEnabled)
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.main.async { [weak self] in
            self?.navigationController?.navigationBar.sizeToFit()
        }
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        // TODO: implement updating accounts
        print("yo")
        dismissAnimated()
    }
    
}

extension EditAccountsViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        
    }
    
}

extension EditAccountsViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return cellModels.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellOfType(CoinDerivationTableViewCell.self, for: indexPath)
        let model = cellModels[indexPath.row]
        cell.setup(coinDerivation: model.coinDerivation, isEnabled: model.isEnabled, delegate: self)
        return cell
    }
    
}

extension EditAccountsViewController: CoinDerivationTableViewCellDelegate {
    
    func didToggleSwitch(_ sender: CoinDerivationTableViewCell) {
        // TODO: update model
    }
    
}
