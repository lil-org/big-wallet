import UIKit
import SPDiffable
import Constants

class ChooseNetworkController: SPDiffableTableController {
    
    private var didSelectNetwork: (EthereumChain) -> Void
    private let lastSelectedNetwork = Flags.last_selected_network
    
    init(didSelectNetwork: @escaping (EthereumChain) -> Void) {
        self.didSelectNetwork = didSelectNetwork
        super.init(style: .insetGrouped)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = Texts.Wallet.Operation.choose_network_header
        configureDiffable(
            sections: content,
            cellProviders: [.network] + SPDiffableTableDataSource.CellProvider.default
        )
    }
    
    internal var content: [SPDiffableSection] {
        return [
            .init(
                id: "list-prod",
                header: SPDiffableTextHeaderFooter(text: Texts.Wallet.Operation.prod_networks_header),
                footer: SPDiffableTextHeaderFooter(text: Texts.Wallet.Operation.prod_networks_footer),
                items: EthereumChain.allMainnets.map({ chain in
                    return SPDiffableTableRowSubtitle(
                        id: nil,
                        text: chain.name,
                        subtitle: chain.symbol,
                        icon: nil,
                        accessoryType: lastSelectedNetwork == chain ? .checkmark : .none,
                        selectionStyle: .default,
                        action: { item, indexPath in
                            Flags.last_selected_network = chain
                            self.didSelectNetwork(chain)
                        }
                    )
                })
            ),
            .init(
                id: "list-test",
                header: SPDiffableTextHeaderFooter(text: Texts.Wallet.Operation.test_networks_header),
                footer: SPDiffableTextHeaderFooter(text: Texts.Wallet.Operation.test_networks_footer),
                items: EthereumChain.allTestnets.map({ chain in
                    return SPDiffableTableRowSubtitle(
                        id: nil,
                        text: chain.name,
                        subtitle: chain.symbol,
                        icon: nil,
                        accessoryType: lastSelectedNetwork == chain ? .checkmark : .none,
                        selectionStyle: .default,
                        action: { item,indexPath in
                            Flags.last_selected_network = chain
                            self.didSelectNetwork(chain)
                        }
                    )
                })
            )
        ]
    }
}
