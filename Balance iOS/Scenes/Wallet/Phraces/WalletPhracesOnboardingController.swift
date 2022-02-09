import UIKit
import Constants
import SparrowKit
import NativeUIKit
import SPSafeSymbols

class WalletPhracesOnboardingController: BaseOnbooardingController {
    
    init(wallet: TokenaryWallet) {
        let walletsManager = WalletsManager.shared
        if let mnemonicString = try? walletsManager.exportMnemonic(wallet: wallet) {
            let phraces = mnemonicString.components(separatedBy: " ")
            super.init(controllers: [
                Controllers.Crypto.Import.Phraces.Onboarding.list(phraces: phraces),
                Controllers.Crypto.Import.Phraces.Onboarding.actions(phraces: phraces),
            ])
        } else if let data = try? walletsManager.exportPrivateKey(wallet: wallet) {
            // Here other
            super.init(controllers: [
                Controllers.Crypto.Import.Phraces.Onboarding.actions(phraces: []),
            ])
        } else {
            fatalError()
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
