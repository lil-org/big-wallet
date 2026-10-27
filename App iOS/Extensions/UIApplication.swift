import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import UIKit

extension UIApplication {
    
#if os(iOS)
    func replaceRootViewController(with viewController: UIViewController, in window: UIWindow) {
        window.rootViewController = viewController
    }
#endif
    
}
