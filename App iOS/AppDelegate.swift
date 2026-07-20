// ∅ 2026 lil org

import UIKit

let screenshotMode = false

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    private let walletsManager = WalletsManager.shared
    private let priceService = PriceService.shared
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
        priceService.start()
        walletsManager.start()
        return true
    }

}
