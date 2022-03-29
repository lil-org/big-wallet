// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import SwiftUI
import WalletCore

public typealias ChainType = CoinType

extension ChainType {
    private static var defaultTitle: String = ""
    private static var defaultTicker: String = ""
    private static var defaultIconName: String = ""
    private static var defaultScanURL: (String) -> URL = { _ in URL(staticString: "") }
    private static var transactionScaner: String = ""
    
    public var title: String {
        switch self {
        case .ethereum:
            return "Ethereum"
        case .tezos:
            return "Tezos"
        case .solana:
            return "Solana"
        default:
            return ChainType.defaultTitle
        }
    }
    
    public var ticker: String {
        switch self {
        case .ethereum:
            return "ETH"
        case .tezos:
            return "XTZ"
        case .solana:
            return "SOL"
        default:
            return ChainType.defaultTicker
        }
    }
    
    public var iconName: String {
        switch self {
        case .ethereum:
            return "eth"
        case .tezos:
            return "tez"
        case .solana:
            return "sol"
        default:
            return ChainType.defaultIconName
        }
    }
    
    public var scanURL: (String) -> URL {
        return { addressString in
            switch self {
            case .ethereum:
                return URL.etherscan(address: addressString)
            case .tezos:
                return URL.tezosscan(address: addressString)
            case .solana:
                return URL.solanascan(address: addressString)
            default:
                return ChainType.defaultScanURL(addressString)
            }
        }
    }
    
    public var transactionScaner: String {
        switch self {
        case .ethereum:
            return Strings.viewOnEtherScan
        case .tezos:
            return Strings.viewOnTezosScan
        case .solana:
            return Strings.viewOnSolanaScan
        default:
            return ChainType.transactionScaner
        }
    }
    
    public static var supportedChains: [ChainType] { [.ethereum, .tezos, .solana] }
    
    @frozen public struct SupportedSet: OptionSet {
        public let rawValue: Int
        
        public init(rawValue: Int) { self.rawValue = rawValue }
        
        public static let ethereum: ChainType.SupportedSet = SupportedSet(rawValue: 1 << 0)
        public static let tezos: ChainType.SupportedSet = SupportedSet(rawValue: 1 << 1)
        public static let solana: ChainType.SupportedSet = SupportedSet(rawValue: 1 << 2)
        
        public static let all: SupportedSet = [ethereum, .tezos, .solana]
    }
    
    init?(provider: Web3Provider) {
        switch provider {
        case .ethereum:
            self = .ethereum
        case .solana:
            self = .solana
        case .tezos:
            self = .tezos
        case .unknown:
            return nil
        }
    }
    
    init?(title: String) {
        switch title {
        case ChainType.ethereum.title:
            self = .ethereum
        case ChainType.tezos.title:
            self = .tezos
        case ChainType.solana.title:
            self = .solana
        default:
            return nil
        }
    }
}

extension ChainType: CustomStringConvertible {
    public var description: String {
        "\(String(describing: self.title))(\(String(describing: self.ticker))), \(self.derivationPath())"
    }
}

extension ChainType: Codable {}
