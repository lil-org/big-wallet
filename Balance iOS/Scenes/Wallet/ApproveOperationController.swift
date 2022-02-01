import UIKit
import SPDiffable
import BlockiesSwift
import NativeUIKit
import SFSymbols

class ApproveOperationController: SPDiffableTableController {
    
    private let subject: ApprovalSubject
    private let address: String
    private let meta: String
    private let peerMeta: PeerMeta?
    private let approveCompletion: (ApproveOperationController, Bool) -> Void
    
    // MARK: - Views
    
    let toolBarView = NativeLargeSmallActionToolBarView().do {
        $0.actionButton.set(
            title: "Approve Operation",
            icon: UIImage(SFSymbol.checkmark.circleFill),
            colorise: .init(content: .custom(.white), background: .tint)
        )
        $0.secondActionButton.setTitle("Cancel")
    }
    
    // MARK: - Init
    
    init(subject: ApprovalSubject, address: String, meta: String, peerMeta: PeerMeta?, approveCompletion: @escaping (ApproveOperationController, Bool) -> Void) {
        self.subject = subject
        self.address = address
        self.meta = meta
        self.peerMeta = peerMeta
        self.approveCompletion = approveCompletion
        super.init(style: .insetGrouped)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = subject.title
        
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
        
        if let navigationController = self.navigationController as? NativeNavigationController {
            navigationController.mimicrateToolBarView = self.toolBarView
        }
        
        configureDiffable(sections: content, cellProviders: [.rowDetailMultiLines] + SPDiffableTableDataSource.CellProvider.default, headerFooterProviders: [.largeHeader])
    }
    
    // MARK: - Diffable
    
    enum Item: String {
        
        case operation_type
        case website
        case address
        case meta
        
        var id: String { rawValue }
    }
    
    internal var content: [SPDiffableSection] {
        return [
            .init(
                id: "adress",
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
                items: [
                    SPDiffableTableRow(
                        id: Item.operation_type.id,
                        text: "Type",
                        detail: subject.title,
                        icon: nil,
                        accessoryType: .none,
                        selectionStyle: .none,
                        action: nil
                    ),
                    SPDiffableTableRow(
                        id: Item.website.id,
                        text: "Website",
                        detail:  peerMeta?.name ?? "Unknow",
                        icon: nil,
                        accessoryType: .none,
                        selectionStyle: .none,
                        action: nil
                    ),
                    SPDiffableTableRow(
                        id: Item.meta.id,
                        text: meta,
                        detail: nil,
                        icon: nil,
                        accessoryType: .none,
                        selectionStyle: .none,
                        action: nil
                    )
                ]
            ),
        ]
    }
}
