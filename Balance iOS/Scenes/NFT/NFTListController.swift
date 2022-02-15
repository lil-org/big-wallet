import UIKit
import NativeUIKit
import SPSafeSymbols
import SPDiffable

class NFTListController: SPDiffableCollectionController {
    
    let placeholderView = NativePlaceholderView(
        icon: .init(SPSafeSymbol.square.stackFill, font: .systemFont(ofSize: 48, weight: .semibold)),
        title: "No NFT",
        subtitle: "Here soon appear your NFT\n(development process)"
    )
    
    init() {
        super.init(collectionViewLayout: UICollectionViewFlowLayout())
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        navigationItem.title = Texts.NFT.title
        collectionView.addSubview(placeholderView)
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        placeholderView.layoutCenter()
    }
}
