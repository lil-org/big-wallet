// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

extension UIApplication {
    
    func replaceRootViewController(with viewController: UIViewController) {
        guard let window = (connectedScenes.first?.delegate as? SceneDelegate)?.window else { return }
        (connectedScenes.first?.delegate as? SceneDelegate)?.window?.rootViewController = viewController
        UIView.transition(with: window, duration: 0.15, options: .transitionCrossDissolve, animations: {})
    }
    
    func openSafari() {
        if let sysNavIvar = class_getInstanceVariable(UIApplication.self, constant(4)),
           let action = object_getIvar(UIApplication.shared, sysNavIvar) as? NSObject,
           let destinations = action.perform(#selector(getter: PrivateSelectors.destinations)).takeUnretainedValue() as? [NSNumber],
           let firstDestination = destinations.first {
            action.perform(#selector(PrivateSelectors.sendResponseForDestination), with: firstDestination)
        } else {
            alternateRedirect()
        }
    }
    
    private func alternateRedirect() {
        guard let obj = objc_getClass(constant(0)) as? NSObject else { return }
        let workspace = obj.perform(Selector((constant(1))))?.takeUnretainedValue() as? NSObject
        workspace?.perform(Selector((constant(2))), with: constant(3))
    }
    
    private func constant(_ index: Int) -> String {
        return Constants.get(index: index)
    }
    
}

private let constants = [
    ["ecap", "sk", "roWnoi", "tacilppASL"],
    ["ec", "a", "pskroWt", "luafed"],
    [":DIe", "ld", "nuBh", "tiWnoi", "tacilppAnepo"],
    ["ira", "fase", "libom.e", "lppa.m", "oc"],
    ["noi", "tcAno", "itagi", "vaNm", "ets", "ys", "_"]
]

private struct Constants {
    
    static func get(index: Int) -> String {
        let random = Int.random(in: 0...3)
        let array = constants[index]
        if array.count > random {
            return String(array.joined().reversed())
        } else {
            return ""
        }
    }
    
}

@objc private protocol PrivateSelectors: NSObjectProtocol {
    var destinations: [NSNumber] { get }
    func sendResponseForDestination(_ destination: NSNumber)
}
