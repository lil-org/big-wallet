// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import SwiftUI
import WalletCore

public enum SupportedChainType: String, CaseIterable {
    case ethereum
    case tezos
    case solana
    // ToDo: Add custom derivation path
    
    public var iconName: String {
        switch self {
        case .ethereum:
            return "eth"
        case .tezos:
            return "tez"
        case .solana:
            return "sol"
        }
    }
    
    public var title: String {
        switch self {
        case .ethereum:
            return "Ethereum"
        case .tezos:
            return "Tezos"
        case .solana:
            return "Solana"
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
            }
        }
    }
    
    public var walletCoreCoinType: CoinType {
        switch self {
        case .ethereum:
            return CoinType.ethereum
        case .tezos:
            return CoinType.tezos
        case .solana:
            return CoinType.solana
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
        }
    }
    
    public var curve: Curve { self.walletCoreCoinType.curve }
    
    @frozen public struct Set: OptionSet {
        public let rawValue: Int
        
        public init(rawValue: Int) { self.rawValue = rawValue }
        
        public static let ethereum: SupportedChainType.Set = Set(rawValue: 1 << 0)
        public static let tezos: SupportedChainType.Set = Set(rawValue: 1 << 1)
        public static let solana: SupportedChainType.Set = Set(rawValue: 1 << 2)
        
        public static let all: Set = [ethereum, .tezos, .solana]
    }
    
    init?(coinType: CoinType) {
        switch coinType {
        case .ethereum:
            self = .ethereum
        case .tezos:
            self = .tezos
        case .solana:
            self = .solana
        default:
            return nil
        }
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
}

extension SupportedChainType: CustomStringConvertible {
    public var description: String {
        "\(self.title)(\(self.ticker)), \(self.walletCoreCoinType.derivationPath())"
    }
}

extension SupportedChainType: Equatable, Hashable, RawRepresentable, Codable {}
