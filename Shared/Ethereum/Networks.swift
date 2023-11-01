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
    
    private static let allBundled: [EthereumNetwork] = {
        if let url = Bundle.main.url(forResource: "bundled-networks", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let networks = try? JSONDecoder().decode([EthereumNetwork].self, from: data) {
            return networks
        } else {
            return []
        }
    }()
    
    static func all() -> [EthereumNetwork] {
        return allBundled
    }
    
}
