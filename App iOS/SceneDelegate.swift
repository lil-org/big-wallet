// ∅ 2026 lil org

import UIKit

private let feedbackShortcutItemType = "org.lil.wallet.feedback"

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard (scene as? UIWindowScene) != nil else { return }
        
        if let shortcutItem = connectionOptions.shortcutItem, shortcutItem.type == feedbackShortcutItemType {
            UIApplication.shared.open(.quickFeedbackMail)
        }
        
        if screenshotMode {
            window?.backgroundColor = UIColor(white: 0.137, alpha: 1)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
        WalletsManager.shared.handleExternalWalletStoreChange()
        SafariApprovalVaultHost.shared.reconcile()
    }
    
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        if shortcutItem.type == feedbackShortcutItemType {
            UIApplication.shared.open(.quickFeedbackMail)
        }
        completionHandler(true)
    }

}
