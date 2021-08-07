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
    
    static let all: [EthereumChain] = [.main, .polygon, .optimism]
    
    var name: String {
        switch self {
        case .main:
            return "Ethereum Mainnet"
        case .arbitrum:
            return "Arbitrum"
        case .optimism:
            return "Optimism"
        case .polygon:
            return "Polygon"
        case .binance:
            return "Binance Chain"
        }
    }
    
}
