import UIKit
import NativeUIKit
import SPAlert
import SparrowKit
import SPDiffable
import SFSymbols
import BlockiesSwift
import SPIndicator

class WalletController: NativeProfileController {
    
    internal var walletModel: TokenaryWallet
    
    init(with walletModel: TokenaryWallet) {
        self.walletModel = walletModel
        super.init()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.largeTitleDisplayMode = .never
        headerView.avatarView.isEditable = false
        tableView.register(NativeLeftButtonTableViewCell.self)
        configureDiffable(sections: content, cellProviders: [.button])
        configureHeader()
        
        headerView.emailButton.addAction(.init(handler: { _ in
            SPIndicator.present(title: "Adress Copied", preset: .done)
        }), for: .touchUpInside)
        
        setSpaceBetweenHeaderAndCells(NativeLayout.Spaces.default_more)
    }
    
    internal func configureHeader() {
        if let adress = walletModel.ethereumAddress {
            #warning("fix fit width")
            headerView.nameLabel.text = String(walletModel.id.prefix(16) + "...")
            headerView.emailButton.setTitle(String(adress.prefix(28)) + "...")
            if let image = Blockies(seed: adress.lowercased(), size: 32).createImage() {
                headerView.avatarView.avatarAppearance = .avatar(image)
            }
        }
    }
    
    // MARK: - Diffable
    
    internal enum Item: String, CaseIterable {
        
        case change_name
        case show_phraces
        case sign_out
        case delete_account
        
        var section_id: String { rawValue + "_section" }
        var item_id: String { rawValue + "_row" }
    }
    
    private var content: [SPDiffableSection] {
        return [
            .init(
                id: Item.show_phraces.section_id,
                header: nil,
                footer: SPDiffableTextHeaderFooter(text: "You will see keys for its wallet. Make it private."),
                items: [
                    NativeDiffableLeftButton(
                        id: Item.change_name.item_id,
                        text: "Show Phraces",
                        icon: .init(.eye.circleFill),
                        action: { [weak self] _, _ in
                            guard let self = self else { return }
                            AuthService.auth(on: self) { success in
                                if success {
                                    Presenter.Crypto.showWalletPhraces(wallet: self.walletModel, on: self)
                                }
                            }
                        }
                    )
                ]
            ),
            .init(
                id: Item.delete_account.section_id,
                header: nil,
                footer: SPDiffableTextHeaderFooter(text: "Wallet will remove only from your device. You can connect it again later with saving passphrase."),
                items: [
                    NativeDiffableLeftButton(
                        id: Item.delete_account.item_id,
                        text: "Delete Wallet",
                        textColor: .destructiveColor,
                        icon: .init(.trash.fill).withTintColor(.destructiveColor, renderingMode: .alwaysOriginal),
                        action: { [weak self] _, indexPath in
                            guard let self = self else { return }
                            let soruceView = self.tableView.cellForRow(at: indexPath) ?? UIView()
                            AlertService.confirm(
                                title: "Confirm Title",
                                description: "Confirm Descriptipm",
                                actionTitle: "Delete Wallet",
                                desctructive: true,
                                action: { [weak self] in
                                    guard let self = self else { return }
                                    let walletsManager = WalletsManager.shared
                                    do {
                                        try? walletsManager.delete(wallet: self.walletModel)
                                    }
                                    
                                    NotificationCenter.default.post(name: .walletsUpdated)
                                    SPAlert.present(title: "Wallet was Deleted", preset: .done, completion: nil)
                                    self.navigationController?.popViewController()
                                },
                                sourceView: soruceView,
                                presentOn: self
                            )
                        }
                    )
                ]
            )
        ]
    }
}
