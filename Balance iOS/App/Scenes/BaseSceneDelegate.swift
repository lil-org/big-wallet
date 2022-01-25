import UIKit
import SparrowKit

class BaseSceneDelegate: SPWindowSceneDelegate {
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        debug("Scene did enter background, scene " + sceneName(scene))
    }
    
    func sceneDidEnterBackground(_ scene: UIScene) {
        debug("Scene did enter background, scene " + sceneName(scene))
    }
    
    private func sceneName(_ scene: UIScene) -> String {
        return scene.session.configuration.name ?? "Can't get name"
    }
}
