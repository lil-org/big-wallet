import UIKit
import SparrowKit
import NativeUIKit

extension Presenter {
    
    enum Crypto {
        
        static func auth(cancelble: Bool, action: @escaping (Bool)->Void, on viewController: UIViewController) {
            let controller = Controllers.Crypto.auth
            controller.action = action
            let navigationController = NativeNavigationController(rootViewController: controller)
            navigationController.inheritLayoutMarginsForСhilds = true
            
            if cancelble {
                controller.navigationItem.rightBarButtonItem = controller.closeBarButtonItem
            }
            
            applyForm(.modalForm, to: navigationController)
            viewController.present(navigationController)
        }
        
        static func showChangePassword(on viewController: UIViewController) {
            let controller = Controllers.Crypto.change_password
            let navigationController = NativeNavigationController(rootViewController: controller)
            navigationController.inheritLayoutMarginsForСhilds = true
            applyForm(.modalForm, to: navigationController)
            viewController.present(navigationController)
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
        
        enum Extension {
            
            static func showLinkWallet(didSelectWallet: @escaping ((TokenaryWallet, EthereumChain, ChooseWalletExtensionResponseController) -> Void), on viewController: UIViewController) {
                let controller = Controllers.Crypto.Extension.choose_wallet(didSelectWallet: didSelectWallet)
                let navgiationController = NativeNavigationController(rootViewController: controller)
                navgiationController.inheritLayoutMarginsForСhilds = true
                applyForm(.modalForm, to: navgiationController)
                viewController.present(navgiationController)
            }
            
            static func showChangeNetwork(didSelectNetwork: @escaping ((EthereumChain) -> Void), on navigationController: UINavigationController) {
                let controller = Controllers.Crypto.Extension.choose_network(didSelectNetwork: didSelectNetwork)
                navigationController.pushViewController(controller, completion: nil)
            }
            
            static func showApproveSendTransaction(transaction: Transaction, chain: EthereumChain, address: String, peerMeta: PeerMeta?, approveCompletion: @escaping (ApproveSendTransactionController, Bool) -> Void, on viewController: UIViewController) {
                let controller = Controllers.Crypto.wallet_transaction_approve(transaction: transaction, chain: chain, address: address, peerMeta: peerMeta, approveCompletion: approveCompletion)
                let navigationController = NativeNavigationController(rootViewController: controller)
                navigationController.inheritLayoutMarginsForСhilds = true
                applyForm(.modalForm, to: navigationController)
                viewController.present(navigationController)
            }
            
            static func showApproveOperation(subject: ApprovalSubject, address: String, meta: String, peerMeta: PeerMeta?, approveCompletion: @escaping (ApproveOperationController, Bool) -> Void, on viewController: UIViewController) {
                let controller = Controllers.Crypto.wallet_operation_approve(subject: subject, address: address, meta: meta, peerMeta: peerMeta, approveCompletion: approveCompletion)
                let navigationController = NativeNavigationController(rootViewController: controller)
                navigationController.inheritLayoutMarginsForСhilds = true
                applyForm(.modalForm, to: navigationController)
                viewController.present(navigationController)
            }
        }
    }
}
