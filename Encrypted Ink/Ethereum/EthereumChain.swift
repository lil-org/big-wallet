// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

enum EthereumChain: Int {
    case main = 1
    case arbitrum = 42161
    case polygon = 137
    case optimism = 10
    
    var id: Int {
        return rawValue
    }
    
}
