import UIKit
import SparrowKit
import Intercom
import Constants

class RootSceneDelegate: BaseSceneDelegate {
    
    override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        #if targetEnvironment(macCatalyst)
        windowScene.titlebar?.titleVisibility = .hidden
        #endif
        makeKeyAndVisible(in: windowScene, createViewControllerHandler: {
            return Navigation.rootController
        }, tint: UserSettings.tint)
        
        if let url = connectionOptions.userActivities.first?.webpageURL ?? connectionOptions.urlContexts.first?.url {
            wasOpenedWithURL(url, onStart: true)
        }
        
        if let window = self.window {
            Appearance.configure(rootWindow: window)
        }
        
        Intercom.setApiKey(Constants.intercom_key, forAppId: Constants.Bundles.app_id)
        Intercom.registerUnidentifiedUser()
    }
    
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let url = userActivity.webpageURL {
            wasOpenedWithURL(url, onStart: false)
        }
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url {
            wasOpenedWithURL(url, onStart: false)
        }
    }
    
    private func wasOpenedWithURL(_ url: URL, onStart: Bool) {
        launchURL = url
    }
}
