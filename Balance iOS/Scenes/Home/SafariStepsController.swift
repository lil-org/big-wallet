import UIKit
import SPDiffable
import NativeUIKit
import SFSymbols
import SparrowKit
import Constants
import Nuke

class SafariStepsController: NativeHeaderController {
    
    var views: [UIView] = []
    
    init() {
        super.init(
            image: nil,
            title: Texts.Wallet.SafariExtension.Steps.title,
            subtitle: Texts.Wallet.SafariExtension.Steps.description
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    let actionToolbarView = NativeLargeActionToolBarView().do {
        $0.actionButton.set(
            title: Texts.Wallet.SafariExtension.Steps.action,
            icon: UIImage.system("safari.fill"),
            colorise: .init(content: .custom(.white), background: .tint)
        )
        $0.footerLabel.text = Texts.Wallet.SafariExtension.Steps.footer
        
        $0.actionButton.addAction(.init(handler: { _ in
            guard let url = URL(string: Constants.website) else { return }
            UIApplication.shared.open(url)
        }), for: .touchUpInside)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground
        
        if let navigationController = self.navigationController as? NativeNavigationController {
            navigationController.mimicrateToolBarView = actionToolbarView
        }
        
        views.append(SafariStepView(image: Image.Safari.step_1))
        views.append(SafariStepArrowView())
        views.append(SafariStepView(image: Image.Safari.step_2))
        views.append(SafariStepArrowView())
        views.append(SafariStepView(image: Image.Safari.step_3))
        
        scrollView.addSubviews(views)
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        var currrentYPosition: CGFloat = headerView.frame.maxY + NativeLayout.Spaces.default
        
        for view in views {
            switch view {
            case let stepView as SafariStepView:
                stepView.frame.setWidth(scrollView.readableWidth * 0.7)
                stepView.setXCenter()
                stepView.sizeToFit()
                stepView.frame.origin.y = currrentYPosition
            case let arrowView as SafariStepArrowView:
                arrowView.sizeToFit()
                arrowView.setXCenter()
                arrowView.frame.origin.y = currrentYPosition
            default:
                break
            }
            
            currrentYPosition = view.frame.maxY + NativeLayout.Spaces.default_half
        }
        
        scrollView.contentSize = .init(width: scrollView.frame.width, height: currrentYPosition)
    }
    
    class SafariStepArrowView: SPView {
        
        private var imageView = SPImageView(image: .init(SFSymbol.arrow.down).alwaysTemplate, contentMode: .scaleAspectFit).do {
            $0.tintColor = UIColor.tintColor
        }
        
        override func commonInit() {
            super.commonInit()
            addSubview(imageView)
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.setEqualSuperviewBounds()
        }
        
        override func sizeThatFits(_ size: CGSize) -> CGSize {
            return .init(side: 25)
        }
    }
}

class SafariStepView: SPView {
    
    let imageView = SPImageView().do {
        $0.contentMode = .scaleAspectFit
    }
    
    init(image: UIImage) {
        super.init()
        self.imageView.image = image
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func commonInit() {
        super.commonInit()
        roundCorners(radius: 12)
        backgroundColor = .tertiarySystemBackground
        addSubview(imageView)
        imageView.setEqualSuperviewMarginsWithAutoLayout()
    }
    
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let image = (imageView.image ?? UIImage())
        return .init(width: size.width, height: size.width * (image.size.height / image.size.width) + layoutMargins.top + layoutMargins.bottom)
    }
}
