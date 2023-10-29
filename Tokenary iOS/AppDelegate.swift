// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    private let walletsManager = WalletsManager.shared
    private let gasService = GasService.shared
    private let priceService = PriceService.shared
    private let configurationService = ConfigurationService.shared
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        priceService.start()
        gasService.start()
        walletsManager.start()
        configurationService.check()
        return true
    }

}
