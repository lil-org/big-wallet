import UIKit
import SparrowKit
import SPDiffable
import NativeUIKit

class WalletsController: SPDiffableTableController {
    
    // MARK: - Data
    
    internal var wallets: [TokenaryWallet] { WalletsManager.shared.wallets }
    
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
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(WalletTableViewCell.self)
        tableView.register(NativeLeftButtonTableViewCell.self)
        tableView.register(NativeEmptyTableViewCell.self)
        
        configureDiffable(
            sections: content,
            cellProviders: [.button, .wallet, .empty, .chain] + SPDiffableTableDataSource.CellProvider.default
        )
        
        NotificationCenter.default.addObserver(forName: .walletsUpdated, object: nil, queue: nil) { _ in
            self.diffableDataSource?.set(self.content, animated: true)
        }
    }
    
    // MARK: - To Ovveride
    
    internal func didTapWallet(_ walletModel: TokenaryWallet) {}
    
    // MARK: - Diffable
    
    internal enum Section: String {
        
        case list
        
        var id: String { rawValue + "_section" }
    }
    
    enum Item: String {
        
        case emptyWallets
        
        var id: String { return rawValue }
    }
    
    internal var content: [SPDiffableSection] {
        return [
            .init(
                id: Section.list.id,
                header: nil,
                footer: nil,
                items: wallets.isEmpty ? [emptyItem] : walletsItems
            )
        ]
    }
    
    internal var emptyItem: SPDiffableItem {
        return NativeEmptyRowItem(
            id: Item.emptyWallets.id,
            verticalMargins: .large,
            text: "No Wallets",
            detail: "Make new wallet for start"
        )
    }
    
    internal var walletsItems: [SPDiffableItem] {
        return wallets.map({ walletModel in
            SPDiffableWrapperItem(id: walletModel.id, model: walletModel) { item, indexPath in
                self.didTapWallet(walletModel)
            }
        })
    }
}
