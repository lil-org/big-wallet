// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

struct Networks {
    
    static var ethereum: EthereumNetwork {
        return withChainId(EthereumNetwork.ethMainnetChainId)!
    }
    
    static func withChainId(_ chainId: Int?) -> EthereumNetwork? {
        guard let chainId = chainId else { return nil }
        return allBundledDict[chainId]
    }
    
    static func withChainIdHex(_ chainIdHex: String?) -> EthereumNetwork? {
        guard let chainIdHex = chainIdHex, let id = Int(hexString: chainIdHex) else { return nil }
        return allBundledDict[id]
    }
    
    static let allMainnets: [EthereumNetwork] = {
        return allBundled.filter { !$0.isTestnet }
    }()
    
    static let allTestnets: [EthereumNetwork] = {
        return allBundled.filter { $0.isTestnet }
    }()
    
    private static let allBundled: [EthereumNetwork] = {
        return Array(allBundledDict.values.sorted(by: { $0.name < $1.name }))
    }()
    
    private static let allBundledDict: [Int: EthereumNetwork] = {
        if let url = Bundle.main.url(forResource: "bundled-networks", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let bundledNetworks = try? JSONDecoder().decode([Int: BundledNetwork].self, from: data) {
            let mapped = bundledNetworks.compactMap { (key, value) -> (Int, EthereumNetwork)? in
                guard let node = Nodes.getNode(chainId: key) else { return nil }
                let network = EthereumNetwork(chainId: key,
                                              name: value.name,
                                              symbol: value.symbol,
                                              nodeURLString: node,
                                              isTestnet: value.isTest,
                                              mightShowPrice: value.okToShowPriceForSymbol)
                return (key, network)
            }
            let dict = [Int: EthereumNetwork](uniqueKeysWithValues: mapped)
            return dict
        } else {
            return [:]
        }
    }()
    
}
