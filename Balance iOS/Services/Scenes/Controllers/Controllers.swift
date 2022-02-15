import UIKit
import SparrowKit
import SPSafeSymbols

enum Controllers {
    
    enum App {
        
        enum Settings {
            
            static var list: UIViewController { SettingsController() }
            static var appearance: UIViewController { SettingsAppearanceController() }
            static var languages: UIViewController { SettingsLanguageController() }
            static var wallet_style: UIViewController { WalletStyleController() }
        }
        
        static var safari_steps: UIViewController { SafariStepsController() }
        
        enum Onboarding {
            
            static var container: AppContainerOnboardingController { AppContainerOnboardingController() }
            static var hello: UIViewController { OnboardingHelloController() }
            static var features: UIViewController { OnboardingBenefitsController() }
        }
    }
    
    enum Crypto {
        
        static var auth: AuthController { AuthController() }
        static var change_password: UIViewController { ChangePassword() }

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
        
        static func wallet_transaction_approve(transaction: Transaction, chain: EthereumChain, address: String, peerMeta: PeerMeta?, approveCompletion: @escaping (ApproveSendTransactionController, Bool) -> Void) -> ApproveSendTransactionController {
            return ApproveSendTransactionController(transaction: transaction, chain: chain, address: address, peerMeta: peerMeta, approveCompletion: approveCompletion)
        }
        
        static func wallet_operation_approve(subject: ApprovalSubject, address: String, meta: String, peerMeta: PeerMeta?, approveCompletion: @escaping (ApproveOperationController, Bool) -> Void) -> ApproveOperationController {
            return ApproveOperationController(subject: subject, address: address, meta: meta, peerMeta: peerMeta, approveCompletion: approveCompletion)
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
        
        enum NFT {
            
            static var list: UIViewController { NFTListController() }
        }
        
        enum Extension {
            
            static func choose_wallet(didSelectWallet: @escaping (TokenaryWallet, EthereumChain, ChooseWalletExtensionResponseController) -> Void) -> ChooseWalletExtensionResponseController {
                return ChooseWalletExtensionResponseController(didSelectWallet: didSelectWallet)
            }
            
            static func choose_network(didSelectNetwork: @escaping (EthereumChain) -> Void) -> ChooseNetworkController {
                return ChooseNetworkController(didSelectNetwork: didSelectNetwork)
            }
        }
        
        enum Onboarding {
            
            static var container: UIViewController { WalletOnbooardingController() }
            static var set_password: UIViewController { SetPasswrodOnboardingController() }
            static var insert_password: UIViewController { AuthOnboardingController() }
            static var import_wallet: UIViewController { ImportWalletController() }
        }
    }
}
