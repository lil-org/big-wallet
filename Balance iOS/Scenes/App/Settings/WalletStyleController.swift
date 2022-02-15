import UIKit
import SPDiffable

class WalletStyleController: SPDiffableTableController {
    
    init() {
        super.init(style: .insetGrouped)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = Texts.Settings.wallet_style_title
        navigationItem.largeTitleDisplayMode = .never
        configureDiffable(sections: content, cellProviders: SPDiffableTableDataSource.CellProvider.default)
        
        NotificationCenter.default.addObserver(forName: .walletsUpdated, object: nil, queue: nil) { _ in
            self.diffableDataSource?.set(self.content, animated: false, completion: nil)
        }
    }
    
    // MARK: - Diffable
    
    internal var content: [SPDiffableSection] {
        let items = WalletStyle.allCases.map({ style in
            SPDiffableTableRow(
                id: style.id,
                text: style.name,
                detail: nil,
                icon: nil,
                accessoryType: WalletStyle.current == style ? .checkmark : .none,
                selectionStyle: .none) { item, indexPath in
                    WalletStyle.current = style
                    UIFeedbackGenerator.impactOccurred(.light)
                }
        })
        
        return [
            SPDiffableSection(
                id: "list",
                header: SPDiffableTextHeaderFooter(text: Texts.Settings.wallet_style_header),
                footer: SPDiffableTextHeaderFooter(text: Texts.Settings.wallet_style_footer),
                items: items
            )
        ]
    }
}
