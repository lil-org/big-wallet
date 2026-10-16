// ∅ 2026 lil org

import Foundation

extension SafariRequest {

    struct ManualSwitchContext: Equatable, Sendable {
        let ethereumAccount: WalletAccountDescriptor?
        let ethereumChainId: String
        let solanaAccount: WalletAccountDescriptor?

        init(authority: ExtensionBridge.AuthoritySnapshot) {
            ethereumAccount = authority.ethereumAccount
            ethereumChainId = authority.ethereumChainId
            solanaAccount = authority.solanaAccount
        }

        var connectedAccounts: [WalletAccountDescriptor] {
            [ethereumAccount, solanaAccount].compactMap { $0 }
        }

        var initiallyConnectedProviders: Set<InpageProvider> {
            Set(connectedAccounts.map(\.coin.correspondingInpageProvider))
        }
    }
    
    struct Unknown: Sendable {
        
        enum Method: String, Sendable {
            case switchAccount
        }
        
        let method: Method
        
        init?(name: String) {
            guard let method = Method(rawValue: name) else { return nil }
            self.method = method
        }
    }
    
}
