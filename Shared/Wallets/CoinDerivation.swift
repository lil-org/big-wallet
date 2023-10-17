// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import WalletCore

struct CoinDerivation: Equatable {
    let coin: CoinType
    let derivation: Derivation
    
    var title: String {
        return coin.name
    }
    
    static var enabledByDefaultCoinDerivations = [
        CoinDerivation(coin: .ethereum, derivation: .default)
    ]
    
    static var supportedCoinDerivations = [
        CoinDerivation(coin: .ethereum, derivation: .default)
    ]
    
}
