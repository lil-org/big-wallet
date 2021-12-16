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
    
    func showMessageAlert(text: String, completion: (() -> Void)? = nil) {
        let alert = UIAlertController(title: text, message: nil, preferredStyle: .alert)
        let okAction = UIAlertAction(title: Strings.ok, style: .default) { _ in
            completion?()
        }
        alert.addAction(okAction)
        present(alert, animated: true)
    }
    
    func showPasswordAlert(title: String, message: String?, completion: @escaping ((String?) -> Void)) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.isSecureTextEntry = true
            textField.textContentType = .oneTimeCode
        }
        let okAction = UIAlertAction(title: Strings.ok, style: .default) { [weak alert] _ in
            completion(alert?.textFields?.first?.text ?? "")
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel) { _ in
            completion(nil)
        }
        alert.addAction(okAction)
        alert.addAction(cancelAction)
        present(alert, animated: true)
        alert.textFields?.first?.becomeFirstResponder()
    }
    
    func endEditingOnTap() -> UITapGestureRecognizer {
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(endEditing))
        tapGestureRecognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(tapGestureRecognizer)
        return tapGestureRecognizer
    }
    
    @objc func endEditing() {
        view.endEditing(true)
    }
    
}
