import UIKit
import SparrowKit
import NativeUIKit
import SFSymbols
import SceneKit
import Constants

class HelloOnboardingController: NativeHeaderController, OnboardingChildInterface {
    
    weak var onboardingManagerDelegate: OnboardingManagerDelegate?
    
    // MARK: - Init
    
    init() {
        super.init(
            image: nil,
            title: Texts.App.name_long,
            subtitle: "Lets make wallet or import existing wallet. Will do it step by step."
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Views
    
    var balanceLogoView = Rotation3DModelView(sceneName: Constants._3D.Logo.scene_filename, node: Constants._3D.Logo.logo_node)
    
    let actionToolbarView = NativeLargeActionToolBarView().do {
        $0.actionButton.set(
            title: "Start Using",
            icon: UIImage(SFSymbol.play.fill),
            colorise: .init(content: .custom(.white), background: .tint)
        )
        $0.footerLabel.text = "Clicking start you agree with our easy privacy policy about not collect any data."
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scrollView.showsVerticalScrollIndicator = false
        
        if let navigationController = self.navigationController as? NativeNavigationController {
            navigationController.mimicrateToolBarView = actionToolbarView
        }
        
        actionToolbarView.actionButton.addAction(.init(handler: { _ in
            self.onboardingManagerDelegate?.onboardingActionComplete(for: self)
        }), for: .touchUpInside)
        
        scrollView.addSubview(balanceLogoView)
    }
    
    // MARK: - Layout
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        balanceLogoView.frame = .init(side: scrollView.readableWidth * 0.8)
        balanceLogoView.setXCenter()
        balanceLogoView.frame.origin.y = headerView.frame.maxY + NativeLayout.Spaces.default_double * 2
        
        scrollView.contentSize = .init(
            width: view.frame.width,
            height: balanceLogoView.frame.maxY
        )
    }
}
