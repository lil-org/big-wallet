// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

extension UIApplication {
    
    func replaceRootViewController(with viewController: UIViewController) {
        guard let window = (connectedScenes.first?.delegate as? SceneDelegate)?.window else { return }
        (connectedScenes.first?.delegate as? SceneDelegate)?.window?.rootViewController = viewController
        UIView.transition(with: window, duration: 0.15, options: .transitionCrossDissolve, animations: {})
    }
    
    func openSafari() {
        _ = jumpBackToPreviousApp()
    }
    
    private func jumpBackToPreviousApp() -> Bool {
        guard
            let sysNavIvar = class_getInstanceVariable(UIApplication.self, "_systemNavigationAction"),
            let action = object_getIvar(UIApplication.shared, sysNavIvar) as? NSObject,
            let destinations = action.perform(#selector(getter: PrivateSelectors.destinations)).takeUnretainedValue() as? [NSNumber],
            let firstDestination = destinations.first
        else {
            return false
        }
        action.perform(#selector(PrivateSelectors.sendResponseForDestination), with: firstDestination)
        return true
    }
    
}

@objc private protocol PrivateSelectors: NSObjectProtocol {
    var destinations: [NSNumber] { get }
    func sendResponseForDestination(_ destination: NSNumber)
}
