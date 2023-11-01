// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

struct Networks {
    
    static var ethereum: EthereumNetwork {
        return withChainId(EthereumNetwork.ethMainnetChainId)!
    }
    
    static func withChainId(_ chainId: Int?) -> EthereumNetwork? {
        guard let chainId = chainId else { return nil }
        return allBundled[chainId]
    }
    
    static func withChainIdHex(_ chainIdHex: String?) -> EthereumNetwork? {
        guard let chainIdHex = chainIdHex, let id = Int(hexString: chainIdHex) else { return nil }
        return allBundled[id]
    }
    
    private static let allBundled: [Int: EthereumNetwork] = {
        if let url = Bundle.main.url(forResource: "bundled-networks", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let bundledNetworks = try? JSONDecoder().decode([Int: BundledNetwork].self, from: data) {
            let mapped = bundledNetworks.compactMap { (key, value) -> (Int, EthereumNetwork)? in
                guard let node = Nodes.getNode(chainId: key) else { return nil }
                let network = EthereumNetwork(chainId: key, name: value.name, symbol: value.symbol, nodeURLString: node)
                return (key, network)
            }
            let dict = [Int: EthereumNetwork](uniqueKeysWithValues: mapped)
            return dict
        } else {
            return [:]
        }
    }()
    
    static func all() -> [EthereumNetwork] {
        return Array(allBundled.values.sorted(by: { $0.chainId < $1.chainId }))
    }
    
}
