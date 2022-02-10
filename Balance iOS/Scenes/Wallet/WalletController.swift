import UIKit
import NativeUIKit
import SPAlert
import SparrowKit
import SPDiffable
import SPSafeSymbols
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
        configureDiffable(sections: content, cellProviders: [.balance, .buttonMultiLinesMonospaced, .button, .rowDetailMultiLines] + SPDiffableTableDataSource.CellProvider.default, headerFooterProviders: [.largeHeader])
        configureHeader()
        
        headerView.emailButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body, weight: .medium)
        headerView.emailButton.addAction(.init(handler: { _ in
            self.showTextFieldToChangeName()
        }), for: .touchUpInside)
        headerView.namePlaceholderLabel.text = Texts.Wallet.no_name
        headerView.emailButton.setTitle(Texts.Wallet.change_name)
        headerView.emailButton.contentEdgeInsets.top = NativeLayout.Spaces.default_half
        if let address = walletModel.ethereumAddress {
            if let image = Blockies(seed: address.lowercased()).createImage(customScale: 32) {
                headerView.avatarView.avatarAppearance = .avatar(image)
            }
        }
        headerView.nameLabel.text = walletModel.walletName
        headerView.emailButton.setImage(.init(SPSafeSymbol.pencil.circleFill))
        
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
        for data in self.balances.sorted(by: { CLongDouble($0.balance ?? "0")! > CLongDouble($1.balance ?? "0")! }) {
            if let value = data.balance {
                if !Flags.show_empty_balances && value == "0" { continue }
                let item = SPDiffableWrapperItem(id: data.chain.name + "_balance", model: data, action: nil)
                balanceItems.append(item)
            }
        }
        
        var formattedAddress = address
        formattedAddress.insert("\n", at: formattedAddress.index(formattedAddress.startIndex, offsetBy: (formattedAddress.count / 2)))
        
        return [
            SPDiffableSection(
                id: Item.info.section_id,
                header: SPDiffableTextHeaderFooter(text: Texts.Wallet.address),
                footer: nil,
                items: [
                    NativeDiffableLeftButton(
                        id: "address-public-id",
                        text: formattedAddress,
                        textColor: .tintColor,
                        icon: UIImage.init(SPSafeSymbol.doc.onClipboardFill),
                        action: { _, _ in
                            UIPasteboard.general.string = self.walletModel.ethereumAddress
                            SPIndicator.present(title: Texts.Wallet.address_copied, preset: .done)
                        }
                    )
                ]
            ),
            .init(
                id: Item.balances.section_id,
                header: NativeLargeHeaderItem(title: Texts.Wallet.balances_header),
                footer: SPDiffableTextHeaderFooter(text: Texts.Wallet.balances_footer),
                items: balanceItems + [
                    SPDiffableTableRowSwitch(text: Texts.Wallet.show_empty_balances, isOn: Flags.show_empty_balances, action: { [weak self] (isOn) in
                        guard let self = self else { return }
                        Flags.show_empty_balances = isOn
                        self.diffableDataSource?.set(self.content, animated: true, completion: nil)
                    })
                ]
            ),
            .init(
                id: Item.show_phraces.section_id,
                header: SPDiffableTextHeaderFooter(text: Texts.Wallet.access_header),
                footer: SPDiffableTextHeaderFooter(text: Texts.Wallet.access_footer),
                items: [
                    NativeDiffableLeftButton(
                        id: Item.change_name.item_id,
                        text: Texts.Wallet.show_phrase,
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
                header: SPDiffableTextHeaderFooter(text: Texts.Wallet.delete_header),
                footer: SPDiffableTextHeaderFooter(text: Texts.Wallet.delete_footer),
                items: [
                    NativeDiffableLeftButton(
                        id: Item.delete_account.item_id,
                        text: Texts.Wallet.delete_action,
                        textColor: .destructiveColor,
                        icon: .init(.trash.fill).withTintColor(.destructiveColor, renderingMode: .alwaysOriginal),
                        action: { [weak self] _, indexPath in
                            guard let self = self else { return }
                            let soruceView = self.tableView.cellForRow(at: indexPath) ?? UIView()
                            AlertService.confirm(
                                title: Texts.Wallet.delete_confirm_title,
                                description: Texts.Wallet.delete_confirm_description,
                                actionTitle: Texts.Wallet.delete_confirm_action,
                                desctructive: true,
                                action: { [weak self] confirmed in
                                    guard let self = self else { return }
                                    if confirmed {
                                        let walletsManager = WalletsManager.shared
                                        do {
                                            try? walletsManager.delete(wallet: self.walletModel)
                                        }
                                        NotificationCenter.default.post(name: .walletsUpdated)
                                        SPAlert.present(title: Texts.Wallet.delete_confirm_action_completed, preset: .done, completion: nil)
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
        let alertController = UIAlertController(title: Texts.Wallet.new_name_title, message: Texts.Wallet.new_name_description, preferredStyle: .alert)
        let saveAction = UIAlertAction(title: Texts.Wallet.new_name_save, style: .default) { [weak self] _ in
            guard let self = self else { return }
            guard let textField = alertController.textFields?.first else { return }
            guard let text = textField.text else { return }
            self.walletModel.walletName = text
            SPAlert.present(title: Texts.Wallet.new_name_saved, message: nil, preset: .done, completion: nil)
        }
        alertController.addAction(saveAction)
        alertController.addAction(title: Texts.Shared.cancel, style: .cancel, handler: nil)
        alertController.addTextField(
            text: self.walletModel.walletName,
            placeholder: Texts.Wallet.new_name_title,
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

typealias BalanceData = (chain: EthereumChain, balance: String?)
