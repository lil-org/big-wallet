// ∅ 2026 lil org

import WalletCore

extension CoinType {
    
    var name: String {
        switch self {
        case .solana:
            return "Solana"
        case .ethereum:
            return "Ethereum"
        case .near:
            return "Near"
        default:
            fatalError(Strings.somethingWentWrong)
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
        default:
            fatalError(Strings.somethingWentWrong)
        }
    }
    
    static func correspondingToInpageProvider(_ inpageProvider: InpageProvider) -> CoinType? {
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
        default:
            return address
        }
    }
    
}
