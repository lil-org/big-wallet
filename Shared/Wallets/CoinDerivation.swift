// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import WalletCore

struct CoinDerivation: Equatable {
    let coin: CoinType
    let derivation: Derivation
    
    var title: String {
        switch coin {
        case .solana:
            return coin.name + (derivation == .default ? " (Trust Wallet)" : "")
        default:
            return coin.name
        }
    }
    
    static var enabledByDefaultCoinDerivations = [
        CoinDerivation(coin: .ethereum, derivation: .default),
        CoinDerivation(coin: .solana, derivation: .solanaSolana),
        CoinDerivation(coin: .near, derivation: .default)
    ]
    
    static var supportedCoinDerivations = [
        CoinDerivation(coin: .ethereum, derivation: .default),
        CoinDerivation(coin: .solana, derivation: .solanaSolana),
        CoinDerivation(coin: .solana, derivation: .default),
        CoinDerivation(coin: .near, derivation: .default)
    ]
    
}
