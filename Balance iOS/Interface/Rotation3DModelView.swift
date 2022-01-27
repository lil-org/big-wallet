import UIKit
import SceneKit
import SparrowKit

class Rotation3DModelView: SPView {
    
    var sceneView = SCNView()
    
    init(sceneName: String, node: String) {
        let scene = SCNScene(named: sceneName)
        sceneView.scene = scene
        sceneView.backgroundColor = .clear
        
        if let node = scene?.rootNode.childNode(withName: node, recursively: true) {
            let action = SCNAction.rotateBy(
                x: .zero,
                y: CGFloat(GLKMathDegreesToRadians(360)),
                z: .zero,
                duration: 5
            )
            let forever = SCNAction.repeatForever(action)
            node.runAction(forever)
        }
        super.init()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func commonInit() {
        super.commonInit()
        addSubview(sceneView)
        sceneView.setEqualSuperviewBoundsWithAutoLayout()
    }
}
