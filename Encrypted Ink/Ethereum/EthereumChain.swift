// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

enum EthereumChain: Int {
    case ethereum = 1
    case arbitrum = 42161
    case polygon = 137
    case optimism = 10
    case binance = 56
    
    // Testnets
    case arbitrumRinkeby = 421611
    case arbitrumKovan = 144545313136048
    case optimisticKovan = 69
    case ethereumRopsten = 3
    case ethereumKovan = 42
    case ethereumRinkeby = 4
    case ethereumGoerli = 5
    case polygonMumbai = 80001
    case binanceTestnet = 97
    
    var id: Int {
        return rawValue
    }
    
    static let allMainnets: [EthereumChain] = [.ethereum, .polygon, .optimism, .binance, .arbitrum]
    static let allTestnets: [EthereumChain] = [.ethereumRopsten, .ethereumKovan, .ethereumRinkeby, .ethereumGoerli, .optimisticKovan, .arbitrumKovan, .arbitrumRinkeby, .polygonMumbai, .binanceTestnet]
    
    var name: String {
        switch self {
        case .ethereum: return "Ethereum"
        case .arbitrum: return "Arbitrum"
        case .optimism: return "Optimism"
        case .polygon: return "Polygon"
        case .binance: return "Binance Smart Chain"
        case .arbitrumRinkeby: return "Arbitrum Rinkeby"
        case .optimisticKovan: return "Optimistic Kovan"
        case .ethereumGoerli: return "Ethereum Görli"
        case .polygonMumbai: return "Polygon Mumbai"
        case .ethereumRopsten: return "Ethereum Ropsten"
        case .ethereumKovan: return "Ethereum Kovan"
        case .ethereumRinkeby: return "Ethereum Rinkeby"
        case .arbitrumKovan: return "Arbitrum Kovan"
        case .binanceTestnet: return "BSC Testnet"
        }
    }
    
    var symbol: String {
        switch self {
        case .binance, .binanceTestnet:
            return "BNB"
        case .polygon, .polygonMumbai:
            return "MATIC"
        case .arbitrum, .arbitrumKovan, .arbitrumRinkeby, .ethereum, .ethereumGoerli, .ethereumKovan, .ethereumRinkeby, .optimism, .optimisticKovan, .ethereumRopsten:
            return "ETH"
        }
    }
    
    var hasUSDPrice: Bool {
        switch self {
        case .ethereum, .optimism:
            return true
        default:
            return false
        }
    }
    
    var nodeURLString: String {
        switch self {
        case .ethereum: return "https://eth-mainnet.alchemyapi.io/v2/" + Secrets.alchemy
        case .arbitrum: return "https://arb-mainnet.g.alchemy.com/v2/" + Secrets.alchemy
        case .optimism: return "https://mainnet.optimism.io"
        case .polygon: return "https://polygon-mainnet.g.alchemy.com/v2/" + Secrets.alchemy
        case .binance: return "https://bsc-dataseed.binance.org/"
        case .arbitrumRinkeby: return "https://rinkeby.arbitrum.io/rpc"
        case .arbitrumKovan: return "https://kovan5.arbitrum.io/rpc"
        case .optimisticKovan: return "https://kovan.optimism.io"
        case .polygonMumbai: return "https://polygon-mumbai.g.alchemy.com/v2/" + Secrets.alchemy
        case .ethereumRopsten: return "https://eth-ropsten.alchemyapi.io/v2/" + Secrets.alchemy
        case .ethereumKovan: return "https://eth-kovan.alchemyapi.io/v2/" + Secrets.alchemy
        case .ethereumRinkeby: return "https://eth-rinkeby.alchemyapi.io/v2/" + Secrets.alchemy
        case .ethereumGoerli: return "https://eth-goerli.alchemyapi.io/v2/" + Secrets.alchemy
        case .binanceTestnet: return "https://data-seed-prebsc-1-s1.binance.org:8545/"
        }
    }
    
}
