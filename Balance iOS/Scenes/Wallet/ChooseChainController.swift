import UIKit
import SPDiffable
import Constants

class ChooseChainController: SPDiffableTableController {
    
    private var didSelectChain: (EthereumChain) -> Void
    private let lastChoosedChain = Flags.last_selected_ethereum_chain
    
    init(didSelectChain: @escaping (EthereumChain) -> Void) {
        self.didSelectChain = didSelectChain
        super.init(style: .insetGrouped)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "Choose Network"
        configureDiffable(
            sections: content,
            cellProviders: [.chain] + SPDiffableTableDataSource.CellProvider.default
        )
    }
    
    internal var content: [SPDiffableSection] {
        return [
            .init(
                id: "list",
                header: SPDiffableTextHeaderFooter(text: "Available"),
                footer: SPDiffableTextHeaderFooter(text: "You can choose debug or production network for action."),
                items: EthereumChain.allMainnets.map({ chain in
                    return SPDiffableTableRowSubtitle(
                        id: nil,
                        text: chain.name,
                        subtitle: chain.symbol,
                        icon: nil,
                        accessoryType: lastChoosedChain == chain ? .checkmark : .none,
                        selectionStyle: .default,
                        action: { item,indexPath in
                            Flags.last_selected_ethereum_chain = chain
                            self.didSelectChain(chain)
                        }
                    )
                })
            )
        ]
    }
}
