// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

extension UIApplication {
    func replaceRootViewController(with viewController: UIViewController) {
        guard let window = UIApplication.sceneWindow else { return }
        UIApplication.sceneWindow?.rootViewController = viewController
        UIView.transition(with: window, duration: 0.15, options: .transitionCrossDissolve, animations: {})
    }
    
    public static var activeWindow: UIWindow {
        guard
            let activeKeyWindow = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow
        else {
            fatalError("No active window found!")
        }
        return activeKeyWindow
    }
    
    public static var sceneWindow: UIWindow? {
        (UIApplication.shared.connectedScenes.first?.delegate as? SceneDelegate)?.window
    }
}
