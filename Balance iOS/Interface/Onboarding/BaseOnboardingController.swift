import UIKit
import Constants
import SparrowKit
import NativeUIKit
import SPPageController

class BaseOnbooardingController: SPPageController {
    
    internal let controllers: [UIViewController]
    internal var endAction: (()->Void)?
    
    init(controllers: [UIViewController]) {
        
        self.controllers = controllers
        
        var childControllers: [UIViewController] = []
        for controller in controllers {
            let navigationController = NativeNavigationController(rootViewController: controller)
            navigationController.inheritLayoutMarginsForСhilds = true
            navigationController.inheritLayoutMarginsForNavigationBar = true
            navigationController.view.preservesSuperviewLayoutMargins = true
            childControllers.append(navigationController)
        }
        
        super.init(childControllers: childControllers, system: .page)
        
        controllers.forEach { controller in
            let onboardingChildController = controller as! OnboardingChildInterface
            onboardingChildController.onboardingManagerDelegate = self
        }
        
        allowScroll = false
        allowDismissWithGester = false
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension BaseOnbooardingController: OnboardingManagerDelegate {
    
    func onboardingActionComplete(for controller: UIViewController) {
        guard let index = controllers.firstIndex(of: controller) else { return }
        if index == (controllers.count - 1) {
            Flags.seen_tutorial = true
            dismiss(animated: true, completion: {
                self.endAction?()
            })
        } else {
            safeScrollTo(index: index + 1, animated: true)
        }
    }
}
