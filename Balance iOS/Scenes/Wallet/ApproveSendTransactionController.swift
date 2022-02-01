import UIKit
import SPDiffable
import BlockiesSwift
import NativeUIKit
import SFSymbols

class ApproveSendTransactionController: SPDiffableTableController {
    
    // MARK: - Data
    
    private let priceService = PriceService.shared
    private let ethereum = Ethereum.shared
    
    private var transaction: Transaction
    private let chain: EthereumChain
    private let address: String
    private let peerMeta: PeerMeta?
    private let approveCompletion: (ApproveSendTransactionController, Bool) -> Void
    
    // MARK: - Views
    
    let toolBarView = NativeLargeSmallActionToolBarView().do {
        $0.actionButton.set(
            title: "Approve Transaction",
            icon: UIImage(SFSymbol.checkmark.circleFill),
            colorise: .init(content: .custom(.white), background: .tint)
        )
        $0.secondActionButton.setTitle("Cancel")
    }
    
    // MARK: - Init
    
    init(transaction: Transaction, chain: EthereumChain, address: String, peerMeta: PeerMeta?, approveCompletion: @escaping (ApproveSendTransactionController, Bool) -> Void) {
        self.transaction = transaction
        self.chain = chain
        self.address = address
        self.peerMeta = peerMeta
        self.approveCompletion = approveCompletion
        super.init(style: .insetGrouped)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "Send Transaction"
        navigationItem.largeTitleDisplayMode = .never
        
        toolBarView.actionButton.addAction(.init(handler: { _ in
            self.toolBarView.setLoading(true)
            AuthService.auth(cancelble: true, on: self) { authed in
                if authed {
                    self.approveCompletion(self, true)
                } else {
                    self.toolBarView.setLoading(false)
                }
            }
        }), for: .touchUpInside)
        
        toolBarView.secondActionButton.addAction(.init(handler: { _ in
            self.approveCompletion(self, false)
        }), for: .touchUpInside)
        
        configureDiffable(sections: content, cellProviders: [.rowDetailMultiLines] + SPDiffableTableDataSource.CellProvider.default, headerFooterProviders: [.largeHeader])
        
        if let navigationController = self.navigationController as? NativeNavigationController {
            navigationController.mimicrateToolBarView = self.toolBarView
        }
        
        toolBarView.setLoading(true)
        observeEthereumValues()
    }
    
    private func observeEthereumValues() {
        ethereum.prepareTransaction(transaction, chain: chain) { [weak self] updated in
            guard let self = self else { return }
            self.transaction = updated
            self.diffableDataSource?.set(self.content, animated: true, completion: nil)
            self.toolBarView.setLoading(!self.transaction.hasFee)
        }
    }
    
    // MARK: - Diffable
    
    enum Item: String {
        
        case website
        case address
        case value
        case fee
        case gas
        
        var id: String { rawValue }
    }
    
    internal var content: [SPDiffableSection] {
        
        var items: [SPDiffableItem] = [
            SPDiffableTableRow(
                id: Item.website.id,
                text: "Website",
                detail:  peerMeta?.name ?? "Unknow",
                icon: nil,
                accessoryType: .none,
                selectionStyle: .none,
                action: nil
            )
        ]
        
        if let value = transaction.valueWithSymbol(chain: chain, ethPrice: priceService.currentPrice, withLabel: true) {
            items.append(
                SPDiffableTableRow(
                    id: Item.value.id,
                    text: "Value",
                    detail: value,
                    icon: nil,
                    accessoryType: .none,
                    selectionStyle: .none,
                    action: nil
                )
            )
        }
        
        items.append(
            SPDiffableTableRow(
                id: Item.fee.id,
                text: "Fee",
                detail: transaction.feeWithSymbol(chain: chain, ethPrice: priceService.currentPrice),
                icon: nil,
                accessoryType: .none,
                selectionStyle: .none,
                action: nil
            )
        )
        
        items.append(
            SPDiffableTableRow(
                id: Item.gas.id,
                text: "Gas",
                detail: transaction.gasPriceWithLabel(chain: chain),
                icon: nil,
                accessoryType: .none,
                selectionStyle: .none,
                action: nil
            )
        )
        
        return [
            .init(
                id: "address",
                header: NativeLargeHeaderItem(title: "Wallet"),
                footer: SPDiffableTextHeaderFooter(text: "Wallet, who doing this operation. It's shoud be you."),
                items: [
                    SPDiffableTableRow(
                        id: Item.address.id,
                        text: address,
                        detail: nil,
                        icon: Blockies(seed: address.lowercased()).createImage(),
                        accessoryType: .none,
                        selectionStyle: .none,
                        action: nil
                    )
                ]
            ),
            .init(
                id: "data",
                header: NativeLargeHeaderItem(title: "Operation Details"),
                footer: SPDiffableTextHeaderFooter(text: "Please, descide about it operation - approve or not. After action you will be redirect to website."),
                items: items
            )
        ]
    }
}
