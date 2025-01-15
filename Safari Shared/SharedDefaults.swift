// ∅ 2025 lil org

import Foundation

struct SharedDefaults {
    
#if os(macOS)
    static let defaults = UserDefaults(suiteName: "8DXC3N7E7P.group.org.lil.wallet")
#elseif os(iOS)
    static let defaults = UserDefaults(suiteName: "group.org.lil.wallet")
#endif
    
    private static let customEthereumNetworksKey = "customEthereumNetworks"
    private static let customEthereumNetworkNodeKeyPrefix = "customEthereumNetworkNode_"
    
    static func addNetwork(_ network: EthereumNetworkFromDapp) {
        guard let chainId = Int(hexString: network.chainId) else { return }
        let updated = getCustomNetworks() + [network]
        defaults?.setCodable(updated, forKey: customEthereumNetworksKey)
        let nodeKey = customEthereumNetworkNodeKeyPrefix + String(chainId)
        defaults?.set(network.defaultRpcUrl, forKey: nodeKey)
    }
    
    static func getCustomNetworks() -> [EthereumNetworkFromDapp] {
        return defaults?.codableValue(type: [EthereumNetworkFromDapp].self, forKey: customEthereumNetworksKey) ?? []
    }
    
    static func getCustomNetworkNode(chainId: Int) -> String? {
        let key = customEthereumNetworkNodeKeyPrefix + String(chainId)
        return defaults?.string(forKey: key)
    }
    
}
