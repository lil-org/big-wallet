import UIKit
import Constants
import SparrowKit
import NativeUIKit
import SPPageController

class AppContainerOnboardingController: BaseOnbooardingController {
    
    init() {
        super.init(controllers: [
            Controllers.App.Onboarding.hello,
            Controllers.App.Onboarding.features
        ])
        allowScroll = false
        allowDismissWithGester = false
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
