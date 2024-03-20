// ∅ 2024 lil org

import WalletCore

extension CoinType {
    
    var name: String {
        switch self {
        case .solana:
            return "solana"
        case .ethereum:
            return "ethereum"
        case .near:
            return "near"
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
                (Strings.viewOn + " " + "etherscan", URL(string: "https://etherscan.io/address/\(address)")!),
                (Strings.viewOn + " " + "superscan", URL(string: "https://superscan.network/address/\(address)")!),
                (Strings.viewOn + " " + "blockscan", URL(string: "https://blockscan.com/address/\(address)")!)
            ]
        case .near:
            return [(Strings.viewOnNearExplorer, URL(string: "https://explorer.near.org/accounts/\(address)")!)]
        default:
            fatalError(Strings.somethingWentWrong)
        }
    }
    
    static func correspondingToInpageProvider(_ inpageProvider: InpageProvider) -> CoinType? {
        switch inpageProvider {
        case .ethereum:
            return .ethereum
        case .unknown, .multiple:
            return nil
        }
    }
    
}
