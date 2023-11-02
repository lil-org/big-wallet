// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

struct EthereumNetwork: Codable, Equatable {
    
    let chainId: Int
    let name: String
    let symbol: String
    let nodeURLString: String
    let isTestnet: Bool
    
    var symbolIsETH: Bool { return symbol == "ETH" }
    var hasUSDPrice: Bool { return chainId == EthereumNetwork.ethMainnetChainId } // TODO: list more chains with usd price
    var chainIdHexString: String { String.hex(chainId, withPrefix: true) }
    var isEthMainnet: Bool { return chainId == EthereumNetwork.ethMainnetChainId }
    
    static let ethMainnetChainId = 1
    
}
