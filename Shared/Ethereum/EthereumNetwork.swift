// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

struct EthereumNetwork: Codable, Equatable {
    
    let chainId: Int
    let name: String
    let symbol: String
    let nodeURLString: String
    
    var symbolIsETH: Bool { return symbol == "ETH" }
    var hasUSDPrice: Bool { return chainId == 1 } // TODO: list more chains with usd price
    var chainIdHexString: String { String.hex(chainId, withPrefix: true) }
    var isEthMainnet: Bool { return chainId == 1 }
    
}

extension EthereumNetwork {
    
    static var ethereum: EthereumNetwork {
        return withChainId(1)!
    }
    
    static func withChainId(_ chainId: Int?) -> EthereumNetwork? {
        guard let chainId = chainId else { return nil }
        // TODO: get from json / defaults / etc
        // TODO: initialize infura urls correctly (adding api key)
        return EthereumNetwork(chainId: chainId, name: "", symbol: "", nodeURLString: "")
    }
    
    static func withChainIdHex(_ chainIdHex: String?) -> EthereumNetwork? {
        return nil // TODO: implement
    }
    
}
