// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

enum EthereumChain: Int {
    case main = 1
    case arbitrum = 42161
    case polygon = 137
    case optimism = 10
    case binance = 56
    
    var id: Int {
        return rawValue
    }
    
    static let all: [EthereumChain] = [.main, .polygon, .optimism, .binance, .arbitrum]
    
    var name: String {
        switch self {
        case .main: return "Ethereum Mainnet"
        case .arbitrum: return "Arbitrum"
        case .optimism: return "Optimism"
        case .polygon: return "Polygon"
        case .binance: return "Binance Smart Chain"
        }
    }
    
    var symbol: String {
        switch self {
        case .main, .arbitrum, .optimism:
            return "ETH"
        case .binance:
            return "BNB"
        case .polygon:
            return "MATIC"
        }
    }
    
    var hasUSDPrice: Bool {
        switch self {
        case .main, .arbitrum, .optimism:
            return true
        case .binance, .polygon:
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
        }
    }
    
}
