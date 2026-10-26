import Foundation

public struct NetworkResolver: AuthorityNetworkCatalog {
    public let catalogIsAvailable: Bool

    private let catalogOwnedChainIds: Set<Int>
    private let resolvedCatalogByChainId: [Int: ResolvedEthereumNetwork]
    private let customSnapshot: @Sendable () -> CustomNetworkSnapshot
    private let freshCustomSnapshot: @Sendable () -> CustomNetworkSnapshotLoadResult

    public init(catalog: NetworkCatalog?,
         catalogOwnedChainIds: Set<Int>,
         decodedChainIds: Set<Int> = [],
         catalogURLBuilder: (NetworkCatalogRecord) -> URL? = {
             record in
             return record.rpcURL()
         },
        customSnapshot: @escaping @Sendable () -> CustomNetworkSnapshot,
        freshCustomSnapshot: (@Sendable () -> CustomNetworkSnapshotLoadResult)? = nil
    ) {
        let catalogMatchesOwnership = catalog?.records.count == catalogOwnedChainIds.count
            && catalog?.records.allSatisfy {
                catalogOwnedChainIds.contains($0.chainId)
            } == true

        var runtimeOwnedChainIds = catalogOwnedChainIds.union(decodedChainIds)
        if let catalog {
            runtimeOwnedChainIds.formUnion(catalog.records.lazy.map(\.chainId))
        }
        self.catalogOwnedChainIds = runtimeOwnedChainIds
        self.customSnapshot = customSnapshot
        self.freshCustomSnapshot = freshCustomSnapshot ?? { .loaded(customSnapshot()) }

        guard let catalog, catalogMatchesOwnership else {
            self.catalogIsAvailable = false
            self.resolvedCatalogByChainId = [:]
            return
        }

        var resolvedCatalogByChainId: [Int: ResolvedEthereumNetwork] = [:]
        for record in catalog.records {
            guard let rpcURL = catalogURLBuilder(record) else { continue }
            let network = record.ethereumNetwork(rpcURL: rpcURL)
            resolvedCatalogByChainId[record.chainId] = ResolvedEthereumNetwork(
                network: network,
                source: record.rpcSource
            )
        }

        self.catalogIsAvailable = true
        self.resolvedCatalogByChainId = resolvedCatalogByChainId
    }


    public var bundledNetworks: [EthereumNetwork] {
        return resolvedCatalogByChainId.values
            .map(\.network)
            .sorted {
                if $0.name == $1.name {
                    return $0.chainId < $1.chainId
                }
                return $0.name < $1.name
            }
    }

    public func resolve(chainId: Int) -> EthereumNetworkResolution {
        if let resolvedNetwork = resolvedCatalogByChainId[chainId] {
            return .resolved(resolvedNetwork)
        }

        if catalogOwnedChainIds.contains(chainId) {
            return .catalogOwnedButUnavailable
        }

        guard let resolvedNetwork = customSnapshot().entriesByChainId[chainId]?.resolvedNetwork else {
            return .unknown
        }
        return .resolved(resolvedNetwork)
    }

    public func approvalResolution(
        chainId: Int,
        freshCustomSnapshot: () -> CustomNetworkSnapshotLoadResult
    ) -> ApprovalNetworkResolution {
        if let network = resolvedCatalogByChainId[chainId] {
            return .resolved(network)
        }
        if catalogOwnedChainIds.contains(chainId) { return .unavailable }
        switch freshCustomSnapshot() {
        case .loaded(let snapshot):
            guard let network = snapshot.entriesByChainId[chainId]?.resolvedNetwork else { return .missing }
            return .resolved(network)
        case .unavailable, .corrupt:
            return .unavailable
        }
    }

    public func rpcURL(chainId: Int) -> URL? {
        return resolve(chainId: chainId).resolvedNetwork?.rpcURL
    }

    public func network(chainId: Int) -> EthereumNetwork? {
        return resolve(chainId: chainId).resolvedNetwork?.network
    }

    public var visibleCustomNetworks: [EthereumNetwork] {
        return customSnapshot().orderedEntries.compactMap { entry in
            guard !catalogOwnedChainIds.contains(entry.chainId) else { return nil }
            return entry.resolvedNetwork.network
        }
    }


    public func approvalResolution(chainId: Int) -> ApprovalNetworkResolution {
        approvalResolution(chainId: chainId, freshCustomSnapshot: freshCustomSnapshot)
    }

    public func resolution(chainId: Int) -> EthereumNetworkResolution { resolve(chainId: chainId) }

    public func network(chainIdHex: String?) -> EthereumNetwork? {
        chainIdHex.flatMap { Int(hexString: $0) }.flatMap { network(chainId: $0) }
    }

    public var allNetworks: [EthereumNetwork] {
        let pinnedIDs = [1, 7777777, 10, 8453, 42161]
        let pinned = pinnedIDs.compactMap { network(chainId: $0) }
        let remaining = bundledNetworks.filter { !pinnedIDs.contains($0.chainId) }
        return pinned + visibleCustomNetworks + remaining.filter { !$0.isTestnet } + remaining.filter { $0.isTestnet }
    }
}
