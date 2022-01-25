import UIKit
import SparrowKit

class SettingsSceneDelegate: BaseSceneDelegate {

    override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        #if targetEnvironment(macCatalyst)
        windowScene.titlebar?.titleVisibility = .hidden
        #endif
        makeKeyAndVisible(in: windowScene, createViewControllerHandler: {
            return Controllers.App.settings
        }, tint: UserSettings.tint)
    }
}
