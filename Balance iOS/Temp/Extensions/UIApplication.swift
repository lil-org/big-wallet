// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

extension UIApplication {
    
    func replaceRootViewController(with viewController: UIViewController) {
        guard let window = (connectedScenes.first?.delegate as? RootSceneDelegate)?.window else { return }
        (connectedScenes.first?.delegate as? RootSceneDelegate)?.window?.rootViewController = viewController
        UIView.transition(with: window, duration: 0.15, options: .transitionCrossDissolve, animations: {})
    }
    
}
