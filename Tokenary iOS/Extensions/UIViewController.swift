// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

extension UIViewController {
    
    var inNavigationController: UINavigationController {
        let navigationController = UINavigationController()
        navigationController.viewControllers = [self]
        return navigationController
    }
    
    @objc func dismissAnimated() {
        dismiss(animated: true)
    }
    
}
