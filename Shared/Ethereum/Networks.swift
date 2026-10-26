import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

@MainActor
struct Networks {
    
    static var ethereum: EthereumNetwork? {
        return withChainId(EthereumNetwork.ethMainnetChainId)
    }
    
    static func withChainId(_ chainId: Int?) -> EthereumNetwork? {
        guard let chainId = chainId else { return nil }
        return ApplicationServices.shared.networks.network(chainId: chainId)
    }
    
    static func withChainIdHex(_ chainIdHex: String?) -> EthereumNetwork? {
        guard let chainIdHex = chainIdHex, let id = Int(hexString: chainIdHex) else { return nil }
        return withChainId(id)
    }
    
    private static let pinnedIds = [1, 7777777, 10, 8453, 42161]
    
    static let pinned: [EthereumNetwork] = {
        return pinnedIds.compactMap { Networks.withChainId($0) }
    }()
    
    static var custom: [EthereumNetwork] {
        return ApplicationServices.shared.networks.visibleCustomNetworks
    }
    
    static let mainnets: [EthereumNetwork] = {
        let excluded = Set(pinnedIds)
        return allBundled.filter { !$0.isTestnet && !excluded.contains($0.chainId) }
    }()
    
    static let testnets: [EthereumNetwork] = {
        return allBundled.filter { $0.isTestnet }
    }()
    
    private static let allBundled: [EthereumNetwork] = {
        return ApplicationServices.shared.networks.bundledNetworks
    }()
    
    // The order networks are offered in, everywhere. Not cached: custom networks are read live,
    // so a chain added by a dapp shows up right away.
    static var ordered: [EthereumNetwork] {
        return pinned + custom + mainnets + testnets
    }

}
