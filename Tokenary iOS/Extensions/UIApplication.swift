// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

extension UIApplication {
    
    func replaceRootViewController(with viewController: UIViewController) {
        guard let window = (connectedScenes.first?.delegate as? SceneDelegate)?.window else { return }
        (connectedScenes.first?.delegate as? SceneDelegate)?.window?.rootViewController = viewController
        UIView.transition(with: window, duration: 0.15, options: .transitionCrossDissolve, animations: {})
    }
    
    func openSafari() {
        guard let obj = objc_getClass("LSApplicationWorkspace") as? NSObject else { return }
        let workspace = obj.perform(Selector(("defaultWorkspace")))?.takeUnretainedValue() as? NSObject
        workspace?.perform(Selector(("openApplicationWithBundleID:")), with: "com.apple.mobilesafari")
    }
    
}
