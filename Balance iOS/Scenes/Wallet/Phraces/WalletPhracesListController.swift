import UIKit
import NativeUIKit
import SPSafeSymbols
import SPDiffable

class WalletPhracesListController: SPDiffableCollectionController, OnboardingChildInterface {
    
    var onboardingManagerDelegate: OnboardingManagerDelegate?
    
    let actionToolbarView = NativeLargeActionToolBarView().do {
        $0.actionButton.set(
            title: Texts.Wallet.Phrase.action,
            icon: UIImage(SPSafeSymbol.arrow.rightCircleFill),
            colorise: .init(content: .custom(.white), background: .tint)
        )
        $0.footerLabel.text = Texts.Wallet.Phrase.footer
    }
    
    let layout = UICollectionViewFlowLayout().do {
        $0.scrollDirection = .vertical
        $0.sectionInsetReference = .fromLayoutMargins
        $0.minimumLineSpacing = 5
        $0.minimumInteritemSpacing = 5
    }
    
    private var phraces: [String]
    
    init(phraces: [String]) {
        self.phraces = phraces
        super.init(collectionViewLayout: UICollectionViewFlowLayout())
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.title = Texts.Wallet.Phrase.title
        navigationItem.rightBarButtonItem = closeBarButtonItem
        
        view.backgroundColor = .systemGroupedBackground
        collectionView.alwaysBounceVertical = true
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.preservesSuperviewLayoutMargins = false
        
        if let navigationController = self.navigationController as? NativeNavigationController {
            navigationController.mimicrateToolBarView = actionToolbarView
        }
        
        actionToolbarView.actionButton.addAction(.init(handler: { _ in
            self.onboardingManagerDelegate?.onboardingActionComplete(for: self)
        }), for: .touchUpInside)
        
        collectionView.register(PhraceCollectionViewCell.self)
        collectionView.setCollectionViewLayout(layout, animated: false)
        
        configureDiffable(
            sections: content,
            cellProviders: [
                .init(clouser: { collectionView, indexPath, item in
                    let cell = self.collectionView.dequeueReusableCell(withClass: PhraceCollectionViewCell.self, for: indexPath)
                    cell.indexLabel.text = "\(indexPath.row + 1)"
                    cell.textLabel.text = item.id
                    return cell
                })
            ],
            headerAsFirstCell: false
        )
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        if layout.itemSize != itemSize {
            layout.itemSize = itemSize
            self.diffableDataSource?.updateLayout(animated: true, completion: nil)
        }
        
        if let navigationController = self.navigationController {
            collectionView.layoutMargins = .init(horizontal: navigationController.view.layoutMargins.left, vertical: NativeLayout.Spaces.default)
        }
    }
    
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
    }
    
    private var itemSize: CGSize {
        let aproximateWidth: CGFloat = 160
        let width = collectionView.layoutWidth
        let count = max(1, Int(width / aproximateWidth))
        let widthWithoutSpaces = width - (layout.minimumLineSpacing * CGFloat(count - 1))
        let cellWidth = (widthWithoutSpaces / CGFloat(count)) - 1
        let cell = PhraceCollectionViewCell()
        cell.setWidthAndFit(width: cellWidth)
        let cellHeight = cell.frame.height
        return .init(width: cellWidth.rounded(), height: cellHeight.rounded())
    }
    
    // MARK: - Diffable
    
    enum Section: String {
        
        case list
        
        var id: String { rawValue }
    }
    
    private var content: [SPDiffableSection] {
        var items: [SPDiffableItem] = []
        for phrase in phraces {
            let item = SPDiffableWrapperItem(id: phrase, model: phrase, action: nil)
            items.append(item)
        }
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
