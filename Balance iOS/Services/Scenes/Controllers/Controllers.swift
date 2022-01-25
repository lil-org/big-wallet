import UIKit
import SparrowKit

enum Controllers {
    
    enum App {
        
        static var settings: UIViewController { SettingsController() }
        
        enum Onboarding {
           
            static var container: UIViewController { OnbooardingController() }
            static var hello: UIViewController { HelloOnboardingController() }
        }
    }
    
    enum Crypto {
        
        static var accounts: UIViewController { AccountsController() }
        static var new_wallet_type: UIViewController { ImportController() }
        static var wallets: UIViewController { WalletsController() }
        static func wallet_detail(_ walletModel: TokenaryWallet) -> WalletController {
            return WalletController(with: walletModel)
        }
    }
}
