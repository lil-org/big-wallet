import UIKit
import SparrowKit
import SPDiffable
import NativeUIKit
import Constants

class ChooseWalletExtensionResponseController: WalletsController {
    
    private var didSelectWallet: (TokenaryWallet, EthereumChain, ChooseWalletExtensionResponseController) -> Void
    
    private var choosedChain = Flags.last_selected_network
    
    init(didSelectWallet: @escaping (TokenaryWallet, EthereumChain, ChooseWalletExtensionResponseController) -> Void) {
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
        navigationItem.title = Texts.Wallet.Operation.choose_wallet
        navigationItem.rightBarButtonItem = .init(barButtonSystemItem: .add, target: self, action: #selector(showAddWallet))
    }
    
    // MARK: - Ovveride
    
    override func didTapWallet(_ walletModel: TokenaryWallet) {
        self.didSelectWallet(walletModel, choosedChain, self)
    }
    
    // MARK: - Actions
    
    @objc private func showAddWallet() {
        Presenter.Crypto.showImportWallet(on: self)
    }
    
    // MARK: - Diffable
    
    override var content: [SPDiffableSection] {
        let chainsSection = SPDiffableSection(
            id: "chains_choose",
            header: SPDiffableTextHeaderFooter(text: Texts.Wallet.Operation.choose_network_header),
            footer: SPDiffableTextHeaderFooter(text: Texts.Wallet.Operation.choose_network_footer),
            items: [
                SPDiffableTableRowSubtitle(
                    text: choosedChain.name,
                    subtitle: choosedChain.symbol,
                    accessoryType: .disclosureIndicator,
                    selectionStyle: .default,
                    action: { item, indexPath in
                        guard let navigationController = self.navigationController else { return }
                        Presenter.Crypto.Extension.showChangeNetwork(didSelectNetwork: { choosedChain in
                            self.choosedChain = choosedChain
                            self.diffableDataSource?.set(self.content, animated: true, completion: nil)
                            navigationController.popToRootViewController(animated: true)
                        }, on: navigationController)
                    }
                )
            ]
        )
        
        let walletsSection = SPDiffableSection(
            id: "wallets-list",
            header: SPDiffableTextHeaderFooter(text: Texts.Wallet.Operation.available_wallets_header),
            footer: SPDiffableTextHeaderFooter(text: Texts.Wallet.Operation.available_wallets_footer),
            items: self.wallets.isEmpty ? [emptyItem] : walletsItems
        )
        
        return [chainsSection, walletsSection]
    }
}
