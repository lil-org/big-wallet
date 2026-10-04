// ∅ 2026 lil org

import UIKit

let screenshotMode = false

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    private let walletsManager = WalletsManager.shared
    private let priceService = PriceService.shared
    private var startupTask: Task<Void, Never>?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
        priceService.start()
        let backgroundTask = SafariApprovalVaultHost.backgroundTask(using: application)
        startupTask = Task { [walletsManager] in
            await walletsManager.start()
            await SafariApprovalVaultHost.shared.start(backgroundTask: backgroundTask)
        }
        return true
    }

}
