import UIKit
import SparrowKit
import SPDiffable
import NativeUIKit
import SFSymbols

class HomeController: NativeHeaderTableController {
    
    // MARK: - Data
    
    private var wallets: [TokenaryWallet] { WalletsManager.shared.wallets }
    
    // MARK: - Views
    
    public let headerView = HomeHeaderController()
    
    // MARK: - Init
    
    public init() {
        let keychain = Keychain.shared
        keychain.save(password: "123456")
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
        configureDiffable(
            sections: content,
            cellProviders: [.button, .wallet, .empty],
            headerFooterProviders: [.largeHeader]
        )
        NotificationCenter.default.addObserver(forName: .walletsUpdated, object: nil, queue: nil) { _ in
            self.diffableDataSource?.set(self.content, animated: true)
        }
    }
    
    // MARK: - Actions
    
    @objc private func showAddWallet() {
        Presenter.Crypto.showImportWallet(on: self)
    }
    
    // MARK: - Diffable
    
    internal enum Section: String {
        
        case accounts
        case changePassword
        
        var id: String { rawValue + "_section" }
    }
    
    enum Item: String {
        
        case emptyAccounts
        
        var id: String { return rawValue }
    }
    
    private var content: [SPDiffableSection] {
        
        let accountItems: [SPDiffableItem] = {
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
                return wallets.prefix(5).map({ walletModel in
                    SPDiffableWrapperItem(id: walletModel.id, model: walletModel) { item, indexPath in
                        guard let navigationController = self.navigationController else { return }
                        Presenter.Crypto.showWalletDetail(walletModel, on: navigationController)
                    }
                }) + [
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
                ]
            }
        }()
        
        return [
            .init(
                id: Section.accounts.id,
                header: NativeLargeHeaderItem(
                    title: "Accounts",
                    actionTitle: "See All",
                    action: { item, indexPath in
                        guard let navigationController = self.navigationController else { return }
                        Presenter.Crypto.showWallets(on: navigationController)
                    }
                ),
                footer: nil,
                items: accountItems
            ),
            .init(
                id: Section.changePassword.id,
                header: nil,
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
                                AuthService.auth(on: self) { success in
                                    if success {
                                        Presenter.Crypto.Password.showPasswordSet(action: { _ in }, on: self)
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
    }
}
