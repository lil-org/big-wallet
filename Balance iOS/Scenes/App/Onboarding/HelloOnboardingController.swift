import UIKit
import SparrowKit
import NativeUIKit
import SFSymbols
import SceneKit

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
    
    var sceneView = SCNView()
    
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
        
        let scene = SCNScene(named: "untitled.scn")
        sceneView.scene = scene
        sceneView.backgroundColor = UIColor.white
        scrollView.addSubview(sceneView)
        
        if let node = scene?.rootNode.childNode(withName: "New-002", recursively: true) {
            
            let action = SCNAction.rotateBy(
                x: 0,
                y: CGFloat(GLKMathDegreesToRadians(360)),
                z: 0,
                duration: 5
            )
            let forever = SCNAction.repeatForever(action)
            node.runAction(forever)
        }
        
    }
    
    // MARK: - Layout
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        sceneView.frame = .init(side: scrollView.readableWidth * 0.8)
        sceneView.setXCenter()
        sceneView.frame.origin.y = headerView.frame.maxY + NativeLayout.Spaces.default_double * 2
        
        scrollView.contentSize = .init(
            width: view.frame.width,
            height: sceneView.frame.maxY
        )
    }
}
