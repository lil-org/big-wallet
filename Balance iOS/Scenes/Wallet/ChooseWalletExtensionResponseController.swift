import UIKit
import SparrowKit
import SPDiffable
import NativeUIKit

class ChooseWalletExtensionResponseController: WalletsController {
    
    private var didSelectWallet: (TokenaryWallet, ChooseWalletExtensionResponseController) -> Void
    
    init(didSelectWallet: @escaping (TokenaryWallet, ChooseWalletExtensionResponseController) -> Void) {
        self.didSelectWallet = didSelectWallet
        super.init()
    }
    
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = closeBarButtonItem
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.title = "Choose Wallet"
        navigationItem.rightBarButtonItem = .init(barButtonSystemItem: .add, target: self, action: #selector(showAddWallet))
    }
    
    // MARK: - Ovveride
    
    override func didTapWallet(_ walletModel: TokenaryWallet) {
        self.didSelectWallet(walletModel, self)
    }
    
    // MARK: - Actions
    
    @objc private func showAddWallet() {
        Presenter.Crypto.showImportWallet(on: self)
    }
}
