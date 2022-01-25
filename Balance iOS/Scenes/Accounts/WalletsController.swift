import UIKit
import SparrowKit
import SPDiffable
import NativeUIKit

class WalletsController: SPDiffableTableController {
    
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
        tableView.register(Account2TableViewCell.self)
        tableView.register(NativeLeftButtonTableViewCell.self)
        configureDiffable(
            sections: content,
            cellProviders: [.button, .wallet]
        )
        
        NotificationCenter.default.addObserver(forName: .walletsUpdated, object: nil, queue: nil) { _ in
            self.diffableDataSource?.set(self.content, animated: true)
        }
    }
    
    // MARK: - Actions
    
    @objc private func showAddWallet() {
        Presenter.Crypto.showAddWallet(on: self)
    }
    
    // MARK: - Diffable
    
    internal enum Section: String {
        
        case list
        
        var id: String { rawValue + "_section" }
    }
    
    private var content: [SPDiffableSection] {
        return [
            .init(
                id: Section.list.id,
                header: nil,
                footer: nil,
                items: wallets.map({ walletModel in
                    SPDiffableWrapperItem(id: walletModel.id, model: walletModel) { item, indexPath in
                        guard let navigationController = self.navigationController else { return }
                        Presenter.Crypto.showWalletDetail(walletModel, on: navigationController)
                    }
                })
            )
        ]
    }
}
