// ∅ 2026 lil org

import UIKit

var launchURL: URL?
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
        
        if let url = connectionOptions.userActivities.first?.webpageURL ?? connectionOptions.urlContexts.first?.url {
            wasOpenedWithURL(url)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
    }
    
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let url = userActivity.webpageURL {
            wasOpenedWithURL(url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url {
            wasOpenedWithURL(url)
        }
    }
    
    private func wasOpenedWithURL(_ url: URL) {
        launchURL = url
        NotificationCenter.default.post(name: .receievedWalletRequest, object: nil)
    }
    
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        if shortcutItem.type == feedbackShortcutItemType {
            UIApplication.shared.open(.quickFeedbackMail)
        }
        completionHandler(true)
    }

}
