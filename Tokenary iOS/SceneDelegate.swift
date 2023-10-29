// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

var launchURL: URL?

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard (scene as? UIWindowScene) != nil else { return }
        
        if let url = connectionOptions.userActivities.first?.webpageURL ?? connectionOptions.urlContexts.first?.url {
            wasOpenedWithURL(url, onStart: true)
        }
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
        NotificationCenter.default.post(name: .receievedWalletRequest, object: nil)
    }

}
