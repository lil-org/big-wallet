import UIKit
import Constants
import SparrowKit
import NativeUIKit
import SFSymbols

class WalletOnbooardingController: BaseOnbooardingController {
    
    init() {
        #warning("here need check if user already has password and ask insert old password.")
        super.init(controllers: [
            Controllers.Crypto.Onboarding.set_password,
            Controllers.Crypto.Import.choose_wallet_type
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
