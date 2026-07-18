// ∅ 2026 lil org

struct Networks {
    
    static var ethereum: EthereumNetwork? {
        return withChainId(EthereumNetwork.ethMainnetChainId)
    }
    
    static func withChainId(_ chainId: Int?) -> EthereumNetwork? {
        guard let chainId = chainId else { return nil }
        return NetworkResolver.main.network(chainId: chainId)
    }
    
    @discardableResult
    static func add(networkFromDapp: EthereumNetworkFromDapp) -> Bool {
        return SharedDefaults.addNetwork(networkFromDapp)
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
        return NetworkResolver.main.visibleCustomNetworks
    }
    
    static let mainnets: [EthereumNetwork] = {
        let excluded = Set(pinnedIds)
        return allBundled.filter { !$0.isTestnet && !excluded.contains($0.chainId) }
    }()
    
    static let testnets: [EthereumNetwork] = {
        return allBundled.filter { $0.isTestnet }
    }()
    
    private static let allBundled: [EthereumNetwork] = {
        return NetworkResolver.main.bundledNetworks
    }()
    
}
