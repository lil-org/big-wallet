// Copyright © 2022 Tokenary. All rights reserved.

import WalletCore

extension CoinType {
    
    var name: String {
        switch self {
        case .solana:
            return "Solana"
        default:
            return "Ethereum"
        }
    }
    
    func explorerURL(address: String) -> URL {
        switch self {
        case .solana:
            return URL(string: "https://explorer.solana.com/address/\(address)")!
        default:
            return URL(string: "https://etherscan.io/address/\(address)")!
        }
    }
    
    var viewOnExplorerTitle: String {
        switch self {
        case .solana:
            return Strings.viewOnSolanaExplorer
        default:
            return Strings.viewOnEtherscan
        }
    }
    
}
