// ∅ 2025 lil org

import UIKit

let screenshotMode = false

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    private let walletsManager = WalletsManager.shared
    private let gasService = GasService.shared
    private let priceService = PriceService.shared
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        priceService.start()
        gasService.start()
        walletsManager.start()
        return true
    }

}
