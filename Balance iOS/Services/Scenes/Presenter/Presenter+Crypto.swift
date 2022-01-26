import UIKit
import SparrowKit
import NativeUIKit

extension Presenter {
    
    enum Crypto {
        
        enum Password {
            
            static func showPasswordSet(action: @escaping (Bool)->Void, on viewController: UIViewController) {
                let controller = Controllers.Crypto.Password.set_new
                let navigationController = NativeNavigationController(rootViewController: controller)
                navigationController.inheritLayoutMarginsForСhilds = true
                applyForm(.modalForm, to: navigationController)
                viewController.present(navigationController)
            }
            
            static func showPassowrdInsert(action: @escaping (Bool)->Void, on viewController: UIViewController) {
                let controller = Controllers.Crypto.Password.insert(completion: action)
                let navigationController = NativeNavigationController(rootViewController: controller)
                navigationController.inheritLayoutMarginsForСhilds = true
                applyForm(.modalForm, to: navigationController)
                viewController.present(navigationController)
            }
        }
        
        static func showWalletOnboarding(on viewController: UIViewController) {
            let controller = Controllers.Crypto.Onboarding.container
            applyForm(.modalForm, to: controller)
            viewController.present(controller)
        }
        
        static func showPhracesOnboarding(for wallet: TokenaryWallet, on viewController: UIViewController) {
            let controller = Controllers.Crypto.Import.Phraces.Onboarding.container(for: wallet)
            applyForm(.modalForm, to: controller)
            viewController.present(controller)
        }
        
        static func showImportWallet(on viewController: UIViewController) {
            let controller = Controllers.Crypto.Import.choose_wallet_type
            let navgiationController = NativeNavigationController(rootViewController: controller)
            navgiationController.inheritLayoutMarginsForСhilds = true
            applyForm(.modalForm, to: navgiationController)
            viewController.present(navgiationController)
        }
        
        static func showWallets(on navigationController: UINavigationController) {
            let controller = Controllers.Crypto.wallets
            navigationController.pushViewController(controller, completion: nil)
        }
        
        static func showWalletDetail(_ walletModel: TokenaryWallet, on navigationController: UINavigationController) {
            let controller = Controllers.Crypto.wallet_detail(walletModel)
            navigationController.pushViewController(controller, completion: nil)
        }
        
        static func showWalletPhraces(wallet: TokenaryWallet, on viewController: UIViewController) {
            let controller = Controllers.Crypto.wallet_phraces(wallet)
            applyForm(.modalForm, to: controller)
            viewController.present(controller)
        }
    }
}
