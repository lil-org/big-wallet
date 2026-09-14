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
    static func add(
        networkFromDapp: EthereumNetworkFromDapp
    ) -> CustomNetworkInsertionResult {
        return SharedDefaults.insertNetwork(networkFromDapp)
    }

    static func existingCustomDefinitionResult(
        networkFromDapp: EthereumNetworkFromDapp
    ) -> CustomNetworkInsertionResult {
        guard let chainId = Int(hexString: networkFromDapp.chainId),
              let entry = CustomNetworkCache.shared.snapshot()
                  .entriesByChainId[chainId] else {
            return .unavailable
        }
        let requestedRPCURLs = CustomNetworkDefinition.requestedRPCURLs(
            for: networkFromDapp
        )
        guard !requestedRPCURLs.isEmpty else { return .unavailable }
        return requestedRPCURLs.contains(where: { requestedRPCURL in
            CustomNetworkDefinition.matches(
                requested: networkFromDapp,
                requestedRPCURL: requestedRPCURL,
                existing: entry.definition,
                existingRPCURL: entry.rpcURL
            )
        }) ? .matching : .conflict
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
    
    // The order networks are offered in, everywhere. Not cached: custom networks are read live,
    // so a chain added by a dapp shows up right away.
    static var ordered: [EthereumNetwork] {
        return pinned + custom + mainnets + testnets
    }

}
