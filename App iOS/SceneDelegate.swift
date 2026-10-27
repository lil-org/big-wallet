import WalletDomain
import WalletAuthority
import WalletNetworking
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
        let access = ApplicationServices.shared.access
        let registry = MobileWalletSceneRegistry.shared
        let window = self.window ?? UIWindow(windowScene: windowScene)
        self.window = window
        UIApplication.shared.replaceRootViewController(
            with: MobileWalletRootViewController(access: access), in: window
        )
        registry.register(window)
        window.makeKeyAndVisible()
        
        if let shortcutItem = connectionOptions.shortcutItem, shortcutItem.type == feedbackShortcutItemType {
            UIApplication.shared.open(.quickFeedbackMail)
        }
        
        if screenshotMode {
            window.backgroundColor = UIColor(white: 0.137, alpha: 1)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        guard !isXCTestHostedLaunch else { return }
        ApplicationServices.shared.prewarm()
        foregroundTask?.cancel()
        foregroundTask = Task {
            _ = await ApplicationServices.shared.wallets.reloadFromStore()
            guard !Task.isCancelled else { return }
            await ApplicationServices.shared.authority.reconcileVault()
#if BW_SAFARI_VM_TESTING
            await ApplicationServices.shared.authority.waitForVaultReconciliation()
            await SafariVMMutations.shared.processPending()
#endif
            await ApplicationServices.shared.requests.performMaintenance()
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
