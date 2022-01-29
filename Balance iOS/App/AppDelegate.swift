import UIKit
import SparrowKit

var launchURL: URL?

@main
class AppDelegate: SPAppScenesDelegate {

    private let walletsManager = WalletsManager.shared
    private let gasService = GasService.shared
    private let priceService = PriceService.shared
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        SPLogger.configure(levels: SPLogger.Level.allCases, fileNameMode: .show)

        priceService.start()
        gasService.start()
        walletsManager.start()
        
        return true
    }
    
    // MARK: - Scenes
    
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let activity = options.userActivities.first
        debug("Creating new scene for activity type \(String(describing: activity?.activityType))")
        let sceneActivity = activity as? SceneUserActivity
        return UISceneConfiguration(scene: sceneActivity?.scene ?? .root, role: connectingSceneSession.role)
    }
    
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        sceneSessions.forEach({
            debug("Discard scene with configuration name: \(String(describing: $0.configuration.name ?? "Haven't name"))")
        })
    }
}
