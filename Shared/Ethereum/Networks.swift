// ∅ 2025 lil org

import Foundation

struct Networks {
    
    static var ethereum: EthereumNetwork {
        return withChainId(EthereumNetwork.ethMainnetChainId)!
    }
    
    static func withChainId(_ chainId: Int?) -> EthereumNetwork? {
        guard let chainId = chainId else { return nil }
        return allBundledDict[chainId]
    }
    
    static func explorerURL(chainId: Int, hash: String) -> URL? {
        if let explorer = withChainId(chainId)?.explorer, let url = URL(string: explorer + "/tx/\(hash)") {
            return url
        } else {
            return nil
        }
    }
    
    static func withChainIdHex(_ chainIdHex: String?) -> EthereumNetwork? {
        guard let chainIdHex = chainIdHex, let id = Int(hexString: chainIdHex) else { return nil }
        return allBundledDict[id]
    }
    
    private static let pinnedIds = [1, 7777777, 10, 8453, 42161]
    
    static let pinned: [EthereumNetwork] = {
        return pinnedIds.compactMap { Networks.withChainId($0) }
    }()
    
    static let custom: [EthereumNetwork] = {
        return [] // TODO: implement
    }()
    
    static let mainnets: [EthereumNetwork] = {
        let excluded = Set(pinnedIds)
        return allBundled.filter { !$0.isTestnet && !excluded.contains($0.chainId) }
    }()
    
    static let testnets: [EthereumNetwork] = {
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
                                              mightShowPrice: value.okToShowPriceForSymbol,
                                              explorer: value.blockExplorer)
                return (key, network)
            }
            let dict = [Int: EthereumNetwork](uniqueKeysWithValues: mapped)
            return dict
        } else {
            return [:]
        }
    }()
    
}
