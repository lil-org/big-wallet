import UIKit
import SparrowKit
import NativeUIKit

extension Presenter {
    
    enum App {
        
        static func showOnboarding(on viewController: UIViewController, afterAction: @escaping (()->Void)) {
            let controller = Controllers.App.Onboarding.container
            controller.endAction = afterAction
            applyForm(.modalForm, to: controller)
            viewController.present(controller)
        }
    }
}
