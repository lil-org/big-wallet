// ∅ 2026 lil org

import UIKit

private let feedbackShortcutItemType = "org.lil.wallet.feedback"

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var foregroundTask: Task<Void, Never>?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        if isXCTestHostedLaunch {
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = UIViewController()
            self.window = window
            window.makeKeyAndVisible()
            return
        }
        
        if let shortcutItem = connectionOptions.shortcutItem, shortcutItem.type == feedbackShortcutItemType {
            UIApplication.shared.open(.quickFeedbackMail)
        }
        
        if screenshotMode {
            window?.backgroundColor = UIColor(white: 0.137, alpha: 1)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        guard !isXCTestHostedLaunch else { return }
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
        foregroundTask?.cancel()
        foregroundTask = Task {
            await WalletsManager.shared.handleExternalWalletStoreChange()
            guard !Task.isCancelled else { return }
            await SafariApprovalVaultHost.shared.reconcile()
            await ExtensionBridge.shared.performMaintenance()
        }
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {
        foregroundTask?.cancel()
        foregroundTask = nil
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        guard !isXCTestHostedLaunch else {
            completionHandler(false)
            return
        }
        if shortcutItem.type == feedbackShortcutItemType {
            UIApplication.shared.open(.quickFeedbackMail)
        }
        completionHandler(true)
    }

}
