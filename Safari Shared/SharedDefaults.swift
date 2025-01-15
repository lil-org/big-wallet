// ∅ 2025 lil org

import Foundation

struct SharedDefaults {
    
#if os(macOS)
    static let defaults = UserDefaults(suiteName: "8DXC3N7E7P.group.org.lil.wallet")
#elseif os(iOS)
    static let defaults = UserDefaults(suiteName: "group.org.lil.wallet")
#endif
    
    static func addNetwork(_ network: EthereumNetworkFromDapp) {
        // TODO: implement
    }
    
    static func getCustomNetworks() -> [EthereumNetworkFromDapp] {
        // TODO: implement
        return []
    }
    
    static func getCustomNetworkNode(chainId: Int) -> String? {
        // TODO: implement
        return nil
    }
    
}
