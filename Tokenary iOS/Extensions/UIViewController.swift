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
    
    func showMessageAlert(text: String) {
        let alert = UIAlertController(title: text, message: nil, preferredStyle: .alert)
        let okAction = UIAlertAction.init(title: Strings.ok, style: .default)
        alert.addAction(okAction)
        present(alert, animated: true)
    }
    
}
