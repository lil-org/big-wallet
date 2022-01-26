import UIKit
import SparrowKit
import SFSymbols

enum Controllers {
    
    enum App {
        
        static var settings: UIViewController { SettingsController() }
        
        enum Onboarding {
            
            static var container: AppOnboardingController { AppOnboardingController() }
            static var hello: UIViewController { HelloOnboardingController() }
        }
    }
    
    enum Crypto {
        
        enum Password {
            
            static func insert(completion: @escaping (Bool)->Void) -> UIViewController {
                InsertPasswordController(action: completion)
            }
            
            static var set_new: UIViewController { SetPasswordController() }
        }
        
        
        static var accounts: UIViewController { HomeController() }
        static var wallets: UIViewController { WalletsListController() }
        
        static func wallet_detail(_ walletModel: TokenaryWallet) -> WalletController {
            return WalletController(with: walletModel)
        }
        
        static func wallet_phraces(_ wallet: TokenaryWallet) -> UIViewController {
            return WalletPhracesOnboardingController(wallet: wallet)
        }
        
        static func wallet_private_adress(_ adress: String) -> UIViewController {
            fatalError()
        }
        
        enum Import {
            
            static var choose_wallet_type: UIViewController { ImportWalletController() }
            
            enum Phraces {
                
                enum Onboarding {
                    
                    static func container(for wallet: TokenaryWallet) -> UIViewController {
                        WalletPhracesOnboardingController(wallet: wallet)
                    }
                    
                    static func list(phraces: [String]) -> UIViewController {
                        WalletPhracesListController(phraces: phraces)
                    }
                    
                    static func actions(phraces: [String]) -> UIViewController {
                        WalletPhracesActionsController(phraces: phraces)
                    }
                }
            }
        }
        
        enum Onboarding {
            
            static var container: UIViewController { WalletOnbooardingController() }
            static var set_password: UIViewController { Controllers.Crypto.Password.set_new }
            static var insert_password: UIViewController { Controllers.Crypto.Password.insert(completion: { _ in }) }
            static var import_wallet: UIViewController { ImportWalletController() }
        }
    }
}
