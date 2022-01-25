import UIKit
import SparrowKit
import SPDiffable
import NativeUIKit

class AccountsController: NativeHeaderTableController {
    
    // MARK: - Data
    
    private var wallets: [TokenaryWallet] { WalletsManager.shared.wallets }
    
    // MARK: - Views
    
    public let headerView = AccountsHeaderController()
    
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
        tableView.register(Account2TableViewCell.self)
        tableView.register(NativeLeftButtonTableViewCell.self)
        configureDiffable(
            sections: content,
            cellProviders: [.button, .wallet],
            headerFooterProviders: [.largeHeader]
        )
        NotificationCenter.default.addObserver(forName: .walletsUpdated, object: nil, queue: nil) { _ in
            print("reload!!!")
            self.diffableDataSource?.set(self.content, animated: true)
        }
    }
    
    // MARK: - Actions
    
    @objc private func showAddWallet() {
        Presenter.Crypto.showAddWallet(on: self)
    }
    
    // MARK: - Diffable
    
    internal enum Section: String {
        
        case accounts
        
        var id: String { rawValue + "_section" }
    }
    
    private var content: [SPDiffableSection] {
        return [
            .init(
                id: Section.accounts.id,
                header: NativeLargeHeaderItem(
                    title: "Accounts",
                    actionTitle: "See All",
                    action: { item, indexPath in
#warning("will fix action passing")
                        guard let navigationController = self.navigationController else { return }
                        Presenter.Crypto.showWallets(on: navigationController)
                    }
                ),
                footer: nil,
                items: wallets.prefix(5).map({ walletModel in
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
            )
        ]
    }
}
