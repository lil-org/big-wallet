// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

struct EthereumNetwork: Codable {
    
    let chainId: Int
    let name: String
    let symbol: String
    let nodeURLString: String
    
    var symbolIsETH: Bool { return symbol == "ETH" }
    
}
