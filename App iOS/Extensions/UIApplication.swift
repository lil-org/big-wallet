// ∅ 2026 lil org

import UIKit

extension UIApplication {

#if os(iOS)
    func replaceRootViewController(with viewController: UIViewController) {
        guard let window = (connectedScenes.first?.delegate as? SceneDelegate)?.window else { return }
        (connectedScenes.first?.delegate as? SceneDelegate)?.window?.rootViewController = viewController
        UIView.transition(with: window, duration: 0.15, options: .transitionCrossDissolve, animations: {})
    }
#endif

}
