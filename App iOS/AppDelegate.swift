// ∅ 2026 lil org

import UIKit

let screenshotMode = false
let isXCTestHostedLaunch = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    private lazy var walletsManager = WalletsManager.shared
    private lazy var priceService = PriceService.shared
    private var startupTask: Task<Void, Never>?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        guard !isXCTestHostedLaunch else { return true }
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
        priceService.start()
        let backgroundTask = SafariApprovalVaultHost.backgroundTask(using: application)
        startupTask = Task { [walletsManager] in
            await walletsManager.start()
            await SafariApprovalVaultHost.shared.start(backgroundTask: backgroundTask)
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
