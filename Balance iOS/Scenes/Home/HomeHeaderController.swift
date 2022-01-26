import UIKit
import SparrowKit
import NativeUIKit
import SFSymbols

open class HomeHeaderController: SPView {
    
    private static let backgroundColor: UIColor = .secondarySystemGroupedBackground
    
    let addButton = NativeLargeActionButton().do {
        $0.set(title: "Add Wallet", icon: UIImage(.plus.circleFill), colorise: .tinted)
        $0.higlightStyle = .background
        $0.addTarget(self, action: #selector(didTapAdd), for: .touchUpInside)
    }
    
    let footerAddButton = NativeFooterView(text: "You can import wallets via passphrase, private code and QR code. Also after import ETH boost to 10k$.")
    

    // MARK: - Private
    
    private var extendView = SPView()
    
    // MARK: - Init
    
    open override func commonInit() {
        super.commonInit()
        layoutMargins.bottom = NativeLayout.Spaces.default_double
        backgroundColor = Self.backgroundColor
        addSubviews([extendView, addButton, footerAddButton])
    }
    
    // MARK: - Ovveride
    
    open override var backgroundColor: UIColor? {
        didSet {
            extendView.backgroundColor = backgroundColor
        }
    }
    
    // MARK: - Layout
    
    open override func layoutSubviews() {
        super.layoutSubviews()
        addButton.layout(y: layoutMargins.top)
        addButton.setXToSuperviewLeftMargin()
        footerAddButton.setWidthAndFit(width: addButton.frame.width)
        footerAddButton.frame.origin.x = addButton.frame.origin.x
        footerAddButton.frame.origin.y = addButton.frame.maxY
        extendView.frame = .init(x: .zero, maxY: .zero, width: frame.width, height: 1000)

    }
    
    open override func sizeThatFits(_ size: CGSize) -> CGSize {
        layoutSubviews()
        return .init(width: frame.width, height: footerAddButton.frame.maxY + layoutMargins.bottom)
    }
    
    // MARK: - Actions
    
    @objc func didTapAdd() {
        guard let contorller = self.viewController else { return }
        Presenter.Crypto.showImportWallet(on: contorller)
    }
}
