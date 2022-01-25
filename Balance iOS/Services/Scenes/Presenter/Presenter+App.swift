import UIKit
import SparrowKit
import NativeUIKit

extension Presenter {
    
    enum App {
        
        static func showOnboarding(on viewController: UIViewController) {
            let controller = Controllers.App.Onboarding.container
            applyForm(.modalForm, to: controller)
            viewController.present(controller)
        }
    }
}
