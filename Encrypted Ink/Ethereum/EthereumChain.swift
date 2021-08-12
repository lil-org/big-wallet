// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

enum EthereumChain: Int {
    case main = 1
    case arbitrum = 42161
    case polygon = 137
    case optimism = 10
    case binance = 56
    
    // Testnets
    case arbitrumTestnet = 421611
    case optimisticKovan = 69
    
    var id: Int {
        return rawValue
    }
    
    static let allMainnets: [EthereumChain] = [.main, .polygon, .optimism, .binance, .arbitrum]
    static let allTestnets: [EthereumChain] = [.optimisticKovan, .arbitrumTestnet]
    
    var name: String {
        switch self {
        case .main: return "Ethereum Mainnet"
        case .arbitrum: return "Arbitrum"
        case .optimism: return "Optimism"
        case .polygon: return "Polygon"
        case .binance: return "Binance Smart Chain"
        case .arbitrumTestnet: return "Arbitrum Testnet"
        case .optimisticKovan: return "Optimistic Kovan"
        }
    }
    
    var symbol: String {
        switch self {
        case .binance:
            return "BNB"
        case .polygon:
            return "MATIC"
        default:
            return "ETH"
        }
    }
    
    var hasUSDPrice: Bool {
        switch self {
        case .main, .optimism:
            return true
        default:
            return false
        }
    }
    
    var nodeURLString: String {
        switch self {
        case .main: return "https://eth-mainnet.alchemyapi.io/v2/" + Secrets.alchemy
        case .arbitrum: return "https://arb-mainnet.g.alchemy.com/v2/" + Secrets.alchemy
        case .optimism: return "https://mainnet.optimism.io"
        case .polygon: return "https://polygon-mainnet.g.alchemy.com/v2/" + Secrets.alchemy
        case .binance: return "https://bsc-dataseed.binance.org/"
        case .arbitrumTestnet: return "https://rinkeby.arbitrum.io/rpc"
        case .optimisticKovan: return "https://kovan.optimism.io"
        }
    }
    
}
