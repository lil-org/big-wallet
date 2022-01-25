import UIKit
import AppImport
import SPAlert
import SPIndicator

enum AlertService {
    
    static func confirm(title: String, description: String, actionTitle: String, desctructive: Bool, action: @escaping ()->Void, sourceView: UIView, presentOn controller: UIViewController) {
        let alertController = UIAlertController.init(title: title, message: description, preferredStyle: .actionSheet)
        alertController.popoverPresentationController?.sourceView = sourceView
        alertController.addAction(title: actionTitle, style: desctructive ? .destructive : .default) { [] _ in
            action()
        }
        alertController.addAction(title: "Cancel", style: .cancel, handler: nil)
        controller.present(alertController)
    }
}
