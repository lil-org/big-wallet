// Copyright © 2022 Tokenary. All rights reserved.

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
    
    func explorerURL(address: String) -> URL {
        switch self {
        case .solana:
            return URL(string: "https://explorer.solana.com/address/\(address)")!
        case .ethereum:
            return URL(string: "https://etherscan.io/address/\(address)")!
        case .near:
            return URL(string: "https://explorer.near.org/accounts/\(address)")!
        default:
            fatalError(Strings.somethingWentWrong)
        }
    }
    
    var viewOnExplorerTitle: String {
        switch self {
        case .solana:
            return Strings.viewOnSolanaExplorer
        case .ethereum:
            return Strings.viewOnEtherscan
        case .near:
            return Strings.viewOnNearExplorer
        default:
            fatalError(Strings.somethingWentWrong)
        }
    }
    
}
