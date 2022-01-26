import UIKit
import Constants
import SparrowKit
import NativeUIKit
import SFSymbols

class WalletOnbooardingController: BaseOnbooardingController {
    
    init() {
        super.init(controllers: [
            Keychain.shared.hasPassword ? Controllers.Crypto.Onboarding.insert_password : Controllers.Crypto.Onboarding.set_password,
            Controllers.Crypto.Import.choose_wallet_type
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
