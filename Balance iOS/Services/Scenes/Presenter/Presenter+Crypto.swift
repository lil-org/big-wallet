import UIKit
import SparrowKit
import NativeUIKit

extension Presenter {
    
    enum Crypto {
        
        static func showAddWallet(on viewController: UIViewController) {
            let controller = Controllers.Crypto.new_wallet_type
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
    }
}
