import UIKit
import NativeUIKit
import SPAlert
import SparrowKit
import SPDiffable
import SFSymbols
import BlockiesSwift
import SPIndicator
import Constants

class WalletController: NativeProfileController {
    
    internal var walletModel: TokenaryWallet
    internal var balances: [BalanceData] = []
    
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
        configureDiffable(sections: content, cellProviders: [.balance, .buttonMultiLines, .rowDetailMultiLines] + SPDiffableTableDataSource.CellProvider.default, headerFooterProviders: [.largeHeader])
        configureHeader()
        
        headerView.emailButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body, weight: .medium)
        headerView.emailButton.addAction(.init(handler: { _ in
            self.showTextFieldToChangeName()
        }), for: .touchUpInside)
        headerView.namePlaceholderLabel.text = "No Name"
        headerView.emailButton.setTitle("Change Name")
        headerView.emailButton.contentEdgeInsets.top = NativeLayout.Spaces.default_half
        if let address = walletModel.ethereumAddress {
            if let image = Blockies(seed: address.lowercased(), size: 32).createImage() {
                headerView.avatarView.avatarAppearance = .avatar(image)
            }
        }
        headerView.nameLabel.text = walletModel.walletName
        headerView.emailButton.setImage(.init(SFSymbol.pencil.circleFill))
        
        setSpaceBetweenHeaderAndCells(NativeLayout.Spaces.default_more)
        
        walletModel.getBalances(for: EthereumChain.allMainnets + EthereumChain.allTestnets) { value, chain in
            self.balances.append(BalanceData(chain: chain, balance: value))
            self.diffableDataSource?.set(self.content, animated: true, completion: nil)
        }
        
        NotificationCenter.default.addObserver(forName: .walletsUpdated, object: nil, queue: nil) { notification in
            if let newWalletModel = WalletsManager.shared.wallets.first(where: { $0.id == self.walletModel.id }) {
                self.walletModel = newWalletModel
                self.configureHeader()
                self.diffableDataSource?.set(self.content, animated: true, completion: nil)
            } else {
                self.navigationController?.popViewController()
            }
        }
    }
    
    internal func configureHeader() {
        headerView.nameLabel.text = walletModel.walletName
    }
    
    // MARK: - Diffable
    
    internal enum Item: String, CaseIterable {
        
        case info
        case balances
        case change_name
        case show_phraces
        case sign_out
        case delete_account
        
        var section_id: String { rawValue + "_section" }
        var item_id: String { rawValue + "_row" }
    }
    
    private var content: [SPDiffableSection] {
        let address =  walletModel.ethereumAddress ?? .space
        
        var balanceItems: [SPDiffableItem] = []
        for data in self.balances.sorted(by: { ($0.balance ?? 0) > ($1.balance ?? 0) }) {
            if let value = data.balance {
                if !Flags.show_empty_balances && value == 0 { continue }
                let item = SPDiffableWrapperItem(id: data.chain.name + "_balance", model: data, action: nil)
                balanceItems.append(item)
            }
        }
        
        var formattedAddress = address
        formattedAddress.insert("\n", at: formattedAddress.index(formattedAddress.startIndex, offsetBy: (formattedAddress.count / 2)))
        
        return [
            SPDiffableSection(
                id: Item.info.section_id,
                header: SPDiffableTextHeaderFooter(text: "Address"),
                footer: nil,
                items: [
                    NativeDiffableLeftButton(
                        id: "address-public-id",
                        text: formattedAddress,
                        textColor: .tintColor,
                        icon: UIImage.init(SFSymbol.doc.onClipboardFill),
                        action: { _, _ in
                            UIPasteboard.general.string = self.walletModel.ethereumAddress
                            SPIndicator.present(title: "Adress Copied", preset: .done)
                        }
                    )
                ]
            ),
            .init(
                id: Item.balances.section_id,
                header: NativeLargeHeaderItem(title: "Balances"),
                footer: SPDiffableTextHeaderFooter(text: "We provide info for each network balance."),
                items: balanceItems + [
                    SPDiffableTableRowSwitch(text: "Show Empty Balances", isOn: Flags.show_empty_balances, action: { [weak self] (isOn) in
                        guard let self = self else { return }
                        Flags.show_empty_balances = isOn
                        self.diffableDataSource?.set(self.content, animated: true, completion: nil)
                    })
                ]
            ),
            .init(
                id: Item.show_phraces.section_id,
                header: SPDiffableTextHeaderFooter(text: "Acceess"),
                footer: SPDiffableTextHeaderFooter(text: "You will see the secret phrase for this wallet. Keep it safe."),
                items: [
                    NativeDiffableLeftButton(
                        id: Item.change_name.item_id,
                        text: "Show Phrases",
                        icon: .init(.eye.circleFill),
                        action: { [weak self] _, _ in
                            guard let self = self else { return }
                            AuthService.auth(cancelble: true, on: self) { success in
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
                header: SPDiffableTextHeaderFooter(text: "Danger Zone"),
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
                                action: { [weak self] confirmed in
                                    guard let self = self else { return }
                                    if confirmed {
                                        let walletsManager = WalletsManager.shared
                                        do {
                                            try? walletsManager.delete(wallet: self.walletModel)
                                        }
                                        NotificationCenter.default.post(name: .walletsUpdated)
                                        SPAlert.present(title: "Wallet was Deleted", preset: .done, completion: nil)
                                        self.navigationController?.popViewController()
                                    }
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
    
    internal func showTextFieldToChangeName() {
        let alertController = UIAlertController(title: "New Name", message: "Insert name of wallet", preferredStyle: .alert)
        let saveAction = UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self = self else { return }
            guard let textField = alertController.textFields?.first else { return }
            guard let text = textField.text else { return }
            self.walletModel.walletName = text
            SPAlert.present(title: "Name Updated", message: nil, preset: .done, completion: nil)
        }
        alertController.addAction(saveAction)
        alertController.addAction(title: "Cancel", style: .cancel, handler: nil)
        alertController.addTextField(
            text: self.walletModel.walletName,
            placeholder: "Wallet Name",
            action: .init(handler: { [weak self] _ in
                guard let _ = self else { return }
                guard let textField = alertController.textFields?.first else { return }
                saveAction.isEnabled = (textField.text ?? .space).trim.count > 3
            })
        )
        if let textField = alertController.textFields?.first {
            textField.keyboardType = .default
            textField.autocapitalizationType = .words
        }
        saveAction.isEnabled = false
        self.present(alertController)
    }
}

typealias BalanceData = (chain: EthereumChain, balance: Double?)
