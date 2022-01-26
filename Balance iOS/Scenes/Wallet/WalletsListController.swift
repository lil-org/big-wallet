import UIKit
import SparrowKit
import SPDiffable
import NativeUIKit

class WalletsListController: SPDiffableTableController {
    
    // MARK: - Data
    
    private var wallets: [TokenaryWallet] { WalletsManager.shared.wallets }
    
    // MARK: - Init
    
    public init() {
        super.init(style: .insetGrouped)
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
        navigationItem.title = "Wallets"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = .init(barButtonSystemItem: .add, target: self, action: #selector(showAddWallet))
        tableView.register(WalletTableViewCell.self)
        tableView.register(NativeLeftButtonTableViewCell.self)
        tableView.register(NativeEmptyTableViewCell.self)
        
        configureDiffable(
            sections: content,
            cellProviders: [.button, .wallet, .empty]
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
        
        case list
        
        var id: String { rawValue + "_section" }
    }
    
    enum Item: String {
        
        case emptyWallets
        
        var id: String { return rawValue }
    }
    
    private var content: [SPDiffableSection] {
        
        let items: [SPDiffableItem] = {
            if wallets.isEmpty {
                return [
                    NativeEmptyRowItem(
                        id: Item.emptyWallets.id,
                        verticalMargins: .large,
                        text: "No Wallets",
                        detail: "Make new wallet for start"
                    )
                ]
            } else {
                return wallets.map({ walletModel in
                    SPDiffableWrapperItem(id: walletModel.id, model: walletModel) { item, indexPath in
                        guard let navigationController = self.navigationController else { return }
                        Presenter.Crypto.showWalletDetail(walletModel, on: navigationController)
                    }
                })
            }
        }()
        
        return [
            .init(
                id: Section.list.id,
                header: nil,
                footer: nil,
                items: items
            )
        ]
    }
}
