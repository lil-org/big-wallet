import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import UIKit

let screenshotMode = false
let isXCTestHostedLaunch = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    private lazy var walletsManager = ApplicationServices.shared.wallets
    private lazy var priceService = ApplicationServices.shared.prices
    private var startupTask: Task<Void, Never>?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        guard !isXCTestHostedLaunch else { return true }
        ApplicationServices.shared.prewarm()
        priceService.start()
        let backgroundTask = ApprovalBackgroundActivity.make(using: application)
        startupTask = Task { [walletsManager] in
            await walletsManager.start()
            await ApplicationServices.shared.authority.startVaultReconciliation(backgroundTask: backgroundTask, protectedDataDidBecomeAvailable: UIApplication.protectedDataDidBecomeAvailableNotification)
#if BW_SAFARI_VM_TESTING
            await ApplicationServices.shared.authority.waitForVaultReconciliation()
            await SafariVMMutations.shared.processPending()
#endif
        }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        guard isXCTestHostedLaunch else { return connectingSceneSession.configuration }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        configuration.storyboard = nil
        return configuration
    }

}
