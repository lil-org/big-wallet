// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

struct Networks {
    
    static var ethereum: EthereumNetwork {
        return withChainId(EthereumNetwork.ethMainnetChainId)!
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
