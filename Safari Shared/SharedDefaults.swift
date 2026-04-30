// ∅ 2026 lil org

import Foundation

struct SharedDefaults {
    
#if os(macOS)
    static let suiteName = "8DXC3N7E7P.group.org.lil.wallet"
#else
    static let suiteName = "group.org.lil.wallet"
#endif
    static let defaults = UserDefaults(suiteName: suiteName)
    
    private static let customEthereumNetworksKey = "customEthereumNetworks"
    private static let customEthereumNetworkNodeKeyPrefix = "customEthereumNetworkNode_"

    static func synchronize() {
        defaults?.synchronize()
    }
    
    static func addNetwork(_ network: EthereumNetworkFromDapp) {
        synchronize()
        guard let chainId = Int(hexString: network.chainId) else { return }
        let updated = getCustomNetworks() + [network]
        defaults?.setCodable(updated, forKey: customEthereumNetworksKey)
        let nodeKey = customEthereumNetworkNodeKeyPrefix + String(chainId)
        defaults?.set(network.defaultRpcUrl, forKey: nodeKey)
        synchronize()
    }
    
    static func getCustomNetworks() -> [EthereumNetworkFromDapp] {
        synchronize()
        return defaults?.codableValue(type: [EthereumNetworkFromDapp].self, forKey: customEthereumNetworksKey) ?? []
    }
    
    static func getCustomNetworkNode(chainId: Int) -> String? {
        synchronize()
        let key = customEthereumNetworkNodeKeyPrefix + String(chainId)
        return defaults?.string(forKey: key)
    }
    
}
