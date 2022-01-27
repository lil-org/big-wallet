import UIKit
import SparrowKit
import SPDiffable
import NativeUIKit
import SFSymbols
import Constants

class HomeController: NativeHeaderTableController {
    
    // MARK: - Data
    
    private var wallets: [TokenaryWallet] { WalletsManager.shared.wallets }
    
    // MARK: - Views
    
    public let headerView = HomeHeaderController()
    
    // MARK: - Init
    
    public init() {
        super.init(style: .insetGrouped, headerView: headerView)
    }
    
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Lifecycle
    
    open override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = Texts.App.name_short
        navigationItem.rightBarButtonItem = .init(barButtonSystemItem: .add, target: self, action: #selector(showAddWallet))
        tableView.register(WalletTableViewCell.self)
        tableView.register(NativeLeftButtonTableViewCell.self)
        tableView.register(NativeEmptyTableViewCell.self)
        tableView.register(SafariTableViewCell.self)
        configureDiffable(
            sections: content,
            cellProviders: [.button, .wallet, .empty] + [
                .init(clouser: { tableView, indexPath, item in
                    if item.id == Item.safariSteps.id {
                        let cell = tableView.dequeueReusableCell(withClass: SafariTableViewCell.self, for: indexPath)
                        cell.closeButton.addAction(.init(handler: { _ in
                            Flags.show_safari_extension_advice = false
                            self.diffableDataSource?.set(self.content, animated: true)
                        }), for: .touchUpInside)
                        cell.button.addAction(.init(handler: { _ in
                            Presenter.App.showSafariIntegrationSteps(on: self)
                        }), for: .touchUpInside)
                        return cell
                    }
                    return nil
                })
            ],
            headerFooterProviders: [.largeHeader]
        )
        NotificationCenter.default.addObserver(forName: .walletsUpdated, object: nil, queue: nil) { _ in
            self.diffableDataSource?.set(self.content, animated: true)
        }
        
        setSpaceBetweenHeaderAndCells(NativeLayout.Spaces.default)
    }
    
    // MARK: - Actions
    
    @objc private func showAddWallet() {
        Presenter.Crypto.showImportWallet(on: self)
    }
    
    // MARK: - Diffable
    
    internal enum Section: String {
        
        case safari
        case accounts
        case changePassword
        
        var id: String { rawValue + "_section" }
    }
    
    enum Item: String {
        
        case safariSteps
        case emptyAccounts
        
        var id: String { return rawValue }
    }
    
    private var content: [SPDiffableSection] {
        
        let walletItems: [SPDiffableItem] = {
            if wallets.isEmpty {
                return [
                    NativeEmptyRowItem(
                        id: Item.emptyAccounts.id,
                        verticalMargins: .large,
                        text: "No Wallets",
                        detail: "Make new wallet for start"
                    )
                ]
            } else {
                var items: [SPDiffableItem] = wallets.prefix(5).map({ walletModel in
                    SPDiffableWrapperItem(id: walletModel.id, model: walletModel) { item, indexPath in
                        guard let navigationController = self.navigationController else { return }
                        Presenter.Crypto.showWalletDetail(walletModel, on: navigationController)
                    }
                })
                if wallets.count > 5 {
                    items.append(
                        NativeDiffableLeftButton(
                            text: "Open All Wallets",
                            textColor: .systemBlue,
                            detail: "Total \(wallets.count) wallets",
                            detailColor: .gray,
                            icon: nil,
                            accessoryType: .disclosureIndicator,
                            action: { item, indexPath in
                                guard let navigationController = self.navigationController else { return }
                                Presenter.Crypto.showWallets(on: navigationController)
                            }
                        )
                    )
                }
                return items
            }
        }()
        
        var sections: [SPDiffableSection] = []
        
        if Flags.show_safari_extension_advice {
            sections.append(
                .init(
                    id: Section.safari.id,
                    header: SPDiffableTextHeaderFooter(text: "Advice"),
                    footer: SPDiffableTextHeaderFooter(text: "Its our focus and best feature. Try it."),
                    items: [.init(id: Item.safariSteps.id)]
                )
            )
        }
        
        sections += [
            .init(
                id: Section.accounts.id,
                header: NativeLargeHeaderItem(
                    title: "Wallets",
                    actionTitle: "See All",
                    action: { item, indexPath in
                        guard let navigationController = self.navigationController else { return }
                        Presenter.Crypto.showWallets(on: navigationController)
                    }
                ),
                footer: nil,
                items: walletItems
            ),
            .init(
                id: Section.changePassword.id,
                header: SPDiffableTextHeaderFooter(text: "Danger Zone."),
                footer: SPDiffableTextHeaderFooter(text: "You can change password and please remember new password in somewhere private places."),
                items: [
                    NativeDiffableLeftButton(
                        text: "Change Password",
                        textColor: .tintColor,
                        detail: nil,
                        detailColor: .clear,
                        icon: .init(SFSymbol.key.fill),
                        accessoryType: .disclosureIndicator,
                        action: { item,indexPath in
                            let alertController = UIAlertController(title: "Before change password need auth with old password", message: "Please, insert old password before", preferredStyle: .alert)
                            alertController.addAction(title: "Let's go", style: .default) { _ in
                                AuthService.auth(cancelble: true, on: self) { success in
                                    if success {
                                        Presenter.Crypto.showChangePassword(on: self)
                                    }
                                }
                            }
                            alertController.addAction(title: "Cancel")
                            self.present(alertController)
                        }
                    )
                ]
            )
        ]
        
        return sections
    }
}
