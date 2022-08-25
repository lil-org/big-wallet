// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

enum EthereumChain: Int {
    case ethereum = 1
    case arbitrum = 42161
    case polygon = 137
    case optimism = 10
    case binance = 56
    case avalanche = 43114
    case gnosisChain = 100
    case fantomOpera = 250
    case celo = 42220
    case aurora = 1313161554
    
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
    case avalancheFuji = 43113
    case fantomTestnet = 4002
    case neonDevnet = 245022926
    
    var id: Int {
        return rawValue
    }
    
    var hexStringId: String {
        return "0x" + String(id, radix: 16, uppercase: false)
    }
    
    static func withChainId(_ chainId: String?) -> EthereumChain? {
        guard let chainId = chainId else { return nil }
        if let rawValue = Int(chainId.dropFirst(2), radix: 16) {
            return EthereumChain(rawValue: rawValue)
        } else {
            return nil
        }
    }
    
    static let allMainnets: [EthereumChain] = [.ethereum, .polygon, .optimism, .binance, .arbitrum, .avalanche, .gnosisChain, .fantomOpera, .celo, .aurora]
    static let allTestnets: [EthereumChain] = [.ethereumRopsten, .ethereumKovan, .ethereumRinkeby, .ethereumGoerli, .optimisticKovan, .arbitrumKovan, .arbitrumRinkeby, .polygonMumbai, .binanceTestnet, .avalancheFuji, .fantomTestnet, .neonDevnet]
    
    var name: String {
        switch self {
        case .ethereum: return "Ethereum"
        case .arbitrum: return "Arbitrum"
        case .optimism: return "Optimism"
        case .polygon: return "Polygon"
        case .binance: return "BNB Smart Chain"
        case .avalanche: return "Avalanche"
        case .gnosisChain: return "Gnosis Chain"
        case .fantomOpera: return "Fantom Opera"
        case .celo: return "Celo"
        case .aurora: return "Aurora"
            
        case .arbitrumRinkeby: return "Arbitrum Rinkeby"
        case .optimisticKovan: return "Optimistic Kovan"
        case .ethereumGoerli: return "Ethereum Görli"
        case .polygonMumbai: return "Polygon Mumbai"
        case .ethereumRopsten: return "Ethereum Ropsten"
        case .ethereumKovan: return "Ethereum Kovan"
        case .ethereumRinkeby: return "Ethereum Rinkeby"
        case .arbitrumKovan: return "Arbitrum Kovan"
        case .binanceTestnet: return "BNB Testnet"
        case .avalancheFuji: return "Avalanche FUJI"
        case .fantomTestnet: return "Fantom Testnet"
        case .neonDevnet: return "Neon Devnet"
        }
    }
    
    var symbol: String {
        switch self {
        case .binance, .binanceTestnet:
            return "BNB"
        case .polygon, .polygonMumbai:
            return "MATIC"
        case .arbitrum, .arbitrumKovan, .arbitrumRinkeby, .ethereum, .ethereumGoerli, .ethereumKovan, .ethereumRinkeby, .optimism, .optimisticKovan, .ethereumRopsten, .aurora:
            return "ETH"
        case .avalanche, .avalancheFuji:
            return "AVAX"
        case .gnosisChain:
            return "xDai"
        case .fantomOpera, .fantomTestnet:
            return "FTM"
        case .celo:
            return "CELO"
        case .neonDevnet:
            return "NEON"
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
        case .arbitrum: return "https://arbitrum-mainnet.infura.io/v3/" + Secrets.infura
        case .optimism: return "https://optimism-mainnet.infura.io/v3/" + Secrets.infura
        case .polygon: return "https://polygon-mainnet.infura.io/v3/" + Secrets.infura
        case .binance: return "https://bsc-dataseed.binance.org/"
        case .avalanche: return "https://api.avax.network/ext/bc/C/rpc"
        case .gnosisChain: return "https://rpc.gnosischain.com/"
        case .fantomOpera: return "https://rpc.ftm.tools/"
        case .celo: return "https://rpc.ankr.com/celo"
        case .aurora: return "https://mainnet.aurora.dev"
            
        case .arbitrumRinkeby: return "https://rinkeby.arbitrum.io/rpc"
        case .arbitrumKovan: return "https://kovan5.arbitrum.io/rpc"
        case .optimisticKovan: return "https://kovan.optimism.io"
        case .ethereumRinkeby: return "https://rinkeby.infura.io/v3/" + Secrets.infura
        case .ethereumRopsten: return "https://ropsten.infura.io/v3/" + Secrets.infura
        case .ethereumKovan: return "https://kovan.infura.io/v3/" + Secrets.infura
        case .ethereumGoerli: return "https://goerli.infura.io/v3/" + Secrets.infura
        case .binanceTestnet: return "https://data-seed-prebsc-1-s1.binance.org:8545/"
        case .avalancheFuji: return "https://api.avax-test.network/ext/bc/C/rpc"
        case .polygonMumbai: return "https://polygon-mumbai.infura.io/v3/" + Secrets.infura
        case .fantomTestnet: return "https://rpc.testnet.fantom.network/"
        case .neonDevnet: return "https://proxy.devnet.neonlabs.org/solana"
        }
    }
    
}
