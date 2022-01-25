import UIKit
import SparrowKit
import NativeUIKit

enum Presenter {
    
    // MARK: - Examples
    
    static func presentExample(on viewController: UIViewController) {
        let controller = SPController()
        controller.view.backgroundColor = .systemBackground
        let navigationController = controller.wrapToNavigationController(prefersLargeTitles: false)
        controller.navigationItem.rightBarButtonItem = controller.closeBarButtonItem
        viewController.present(navigationController)
    }
    
    static func pushExample(on navigationController: UINavigationController) {
        let controller = SPController()
        controller.view.backgroundColor = .systemBackground
        navigationController.pushViewController(controller)
    }
    
    // MARK: - Internal
    
    internal enum Form {
        
        case fullScreen
        case modalForm
    }
    
    internal static func applyForm(_ form: Form, to controller: UIViewController) {
        switch form {
        case .fullScreen:
            controller.modalPresentationStyle = .fullScreen
        case .modalForm:
            let horizontalMargin: CGFloat = NativeLayout.Spaces.Margins.modal_screen_horizontal
            controller.modalPresentationStyle = .formSheet
            controller.preferredContentSize = Layout.Sizes.Controller.form_sheet_size
            controller.view.layoutMargins.left = horizontalMargin
            controller.view.layoutMargins.right = horizontalMargin
            
            if let navigationController = controller as? SPNavigationController {
                navigationController.inheritLayoutMarginsForNavigationBar = true
                navigationController.inheritLayoutMarginsForСhilds = true
                navigationController.viewDidLayoutSubviews()
            }
        }
    }
}
