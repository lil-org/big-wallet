import UIKit
import Constants
import SparrowKit
import NativeUIKit
import SPPageController

class OnbooardingController: SPPageController {
    
    let controllers: [UIViewController]
    
    init() {
        controllers = [
            Controllers.App.Onboarding.hello
        ]
        
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
        
        allowScroll = true
        allowDismissWithGester = false
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension OnbooardingController: OnboardingManagerDelegate {
    
    func onboardingActionComplete(for controller: UIViewController) {
        guard let index = controllers.firstIndex(of: controller) else { return }
        if index == (controllers.count - 1) {
            Flags.seen_tutorial = true
            dismissAnimated()
        } else {
            safeScrollTo(index: index + 1, animated: true)
        }
    }
}

protocol OnboardingManagerDelegate: AnyObject {
    
    func onboardingActionComplete(for controller: UIViewController)
}

protocol OnboardingChildInterface: AnyObject {
    
    var onboardingManagerDelegate: OnboardingManagerDelegate? { get set }
}
