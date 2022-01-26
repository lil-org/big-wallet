import UIKit
import Constants
import SparrowKit
import NativeUIKit
import SPPageController

class AppOnboardingController: BaseOnbooardingController {
    
    init() {
        super.init(controllers: [
            Controllers.App.Onboarding.hello
        ])
        allowScroll = false
        allowDismissWithGester = false
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
