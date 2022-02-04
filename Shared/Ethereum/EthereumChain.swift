// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

enum EthereumChain: Int {
    case ethereum = 1
    case arbitrum = 42161
    case polygon = 137
    case optimism = 10
    case binance = 56
    case avalanche = 43114
    case xDai = 100
    
    // Testnets
    case arbitrumRinkeby = 421611
    case optimisticKovan = 69
    case ethereumRopsten = 3
    case ethereumKovan = 42
    case ethereumRinkeby = 4
    case ethereumGoerli = 5
    case polygonMumbai = 80001
    case binanceTestnet = 97
    case avalancheFuji = 43113
    
    var id: Int {
        return rawValue
    }
    
    var hexStringId: String {
        return "0x" + String(id, radix: 16, uppercase: false)
    }
    
    static let allMainnets: [EthereumChain] = [.ethereum, .polygon, .optimism, .binance, .arbitrum, .avalanche, .xDai]
    static let allTestnets: [EthereumChain] = [.ethereumRopsten, .ethereumKovan, .ethereumRinkeby, .ethereumGoerli, .optimisticKovan, .arbitrumRinkeby, .polygonMumbai, .binanceTestnet, .avalancheFuji]
    
    var name: String {
        switch self {
        case .ethereum: return "Ethereum"
        case .arbitrum: return "Arbitrum"
        case .optimism: return "Optimism"
        case .polygon: return "Polygon"
        case .binance: return "Binance Smart Chain"
        case .avalanche: return "Avalanche"
        case .xDai: return "xDai"
        case .arbitrumRinkeby: return "Arbitrum Rinkeby"
        case .optimisticKovan: return "Optimistic Kovan"
        case .ethereumGoerli: return "Ethereum Görli"
        case .polygonMumbai: return "Polygon Mumbai"
        case .ethereumRopsten: return "Ethereum Ropsten"
        case .ethereumKovan: return "Ethereum Kovan"
        case .ethereumRinkeby: return "Ethereum Rinkeby"
        case .binanceTestnet: return "BSC Testnet"
        case .avalancheFuji: return "Avalanche FUJI"
        }
    }
    
    var symbol: String {
        switch self {
        case .binance, .binanceTestnet:
            return "BNB"
        case .polygon, .polygonMumbai:
            return "MATIC"
        case .arbitrum, .arbitrumRinkeby, .ethereum, .ethereumGoerli, .ethereumKovan, .ethereumRinkeby, .optimism, .optimisticKovan, .ethereumRopsten:
            return "ETH"
        case .avalanche, .avalancheFuji:
            return "AVAX"
        case .xDai:
            return "xDai"
        }
    }
    
    var symbolIsETH: Bool {
        return symbol == "ETH"
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
        case .ethereum: return "https://mainnet.infura.io/v3/" + Secrets.infura
        case .arbitrum: return "https://arb1.arbitrum.io/rpc"
        case .optimism: return "https://mainnet.optimism.io"
        case .polygon: return "https://polygon-rpc.com"
        case .binance: return "https://bsc-dataseed.binance.org/"
        case .avalanche: return "https://api.avax.network/ext/bc/C/rpc"
        case .xDai: return "https://rpc.xdaichain.com/"
            
        case .arbitrumRinkeby: return "https://rinkeby.arbitrum.io/rpc"
        case .optimisticKovan: return "https://kovan.optimism.io"
        case .ethereumRinkeby: return "https://rinkeby.infura.io/v3/" + Secrets.infura
        case .ethereumRopsten: return "https://ropsten.infura.io/v3/" + Secrets.infura
        case .ethereumKovan: return "https://kovan.infura.io/v3/" + Secrets.infura
        case .ethereumGoerli: return "https://goerli.infura.io/v3/" + Secrets.infura
        case .binanceTestnet: return "https://data-seed-prebsc-1-s1.binance.org:8545/"
        case .avalancheFuji: return "https://api.avax-test.network/ext/bc/C/rpc"
        case .polygonMumbai: return "https://rpc-mumbai.matic.today"
        }
    }
    
}
