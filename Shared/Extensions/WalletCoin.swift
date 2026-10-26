import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Foundation

extension WalletCoin {
    
    func explorersFor(address: String) -> [(String, URL)] {
        switch self {
        case .solana:
            return [(Strings.viewOnSolanaExplorer, URL(string: "https://explorer.solana.com/address/\(address)")!)]
        case .ethereum:
            return [
                (Strings.viewOn + " " + "Etherscan", URL(string: "https://etherscan.io/address/\(address)")!)
            ]
        }
    }
    
}
