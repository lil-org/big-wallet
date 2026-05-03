// ∅ 2026 lil org

import Foundation

extension WalletCoin {
    
    var name: String {
        switch self {
        case .solana:
            return "Solana"
        case .ethereum:
            return "Ethereum"
        }
    }
    
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
    
    nonisolated static func correspondingToInpageProvider(_ inpageProvider: InpageProvider) -> WalletCoin? {
        switch inpageProvider {
        case .ethereum:
            return .ethereum
        case .solana:
            return .solana
        case .unknown, .multiple:
            return nil
        }
    }

    func normalizedAddress(_ address: String) -> String {
        switch self {
        case .ethereum:
            return address.lowercased()
        case .solana:
            return address
        }
    }
    
}
