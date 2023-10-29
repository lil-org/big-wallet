// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

struct EthereumNetwork {
    
    let id: Int
    let name: String
    let chainId: String
    let symbol: String
    let nodeURLString: String
    
    var symbolIsETH: Bool { return symbol == "ETH" }
    
}
