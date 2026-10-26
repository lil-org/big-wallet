// ∅ 2026 lil org

import Foundation

extension SafariRequest {

    public struct ManualSwitchContext: Equatable, Sendable {
        public let ethereumAccount: WalletAccountDescriptor?
        public let ethereumChainId: String
        public let solanaAccount: WalletAccountDescriptor?

        public init(authority: RequestAuthoritySnapshot) {
            ethereumAccount = authority.ethereumAccount
            ethereumChainId = authority.ethereumChainId
            solanaAccount = authority.solanaAccount
        }

        public var connectedAccounts: [WalletAccountDescriptor] {
            [ethereumAccount, solanaAccount].compactMap { $0 }
        }

        public var initiallyConnectedProviders: Set<InpageProvider> {
            Set(connectedAccounts.map(\.coin.correspondingInpageProvider))
        }
    }
    
    public struct Unknown: Sendable {
        
        public enum Method: String, Sendable {
            case switchAccount
        }
        
        public let method: Method
        
        public init?(name: String) {
            guard let method = Method(rawValue: name) else { return nil }
            self.method = method
        }
    }
    
}
