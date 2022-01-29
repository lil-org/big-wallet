import UIKit
import SparrowKit
import SPDiffable
import NativeUIKit

class WalletsListController: WalletsController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "Wallets"
        navigationItem.rightBarButtonItem = .init(barButtonSystemItem: .add, target: self, action: #selector(showAddWallet))
    }
    
    // MARK: - Ovveride
    
    override func didTapWallet(_ walletModel: TokenaryWallet) {
        guard let navigationController = self.navigationController else { return }
        Presenter.Crypto.showWalletDetail(walletModel, on: navigationController)
    }
    
    // MARK: - Actions
    
    @objc private func showAddWallet() {
        Presenter.Crypto.showImportWallet(on: self)
    }
}
