import Foundation
import WalletDomain

public struct AuthorityRuntimeConfiguration: Sendable {
    public let catalog: NetworkCatalog?
    public let catalogOwnedChainIds: Set<Int>
    public let decodedChainIds: Set<Int>
    public let storage: AuthorityStorageConfiguration
    public let messages: AuthorityMessages

    public init(catalog: NetworkCatalog?, catalogOwnedChainIds: Set<Int>, decodedChainIds: Set<Int> = [],
                storage: AuthorityStorageConfiguration, messages: AuthorityMessages) {
        self.catalog = catalog
        self.catalogOwnedChainIds = catalogOwnedChainIds
        self.decodedChainIds = decodedChainIds
        self.storage = storage
        self.messages = messages
    }
}

@MainActor
struct AuthorityComposition {
    struct Dependencies: Sendable {
        var catalogURLBuilder: @Sendable (NetworkCatalogRecord) -> URL? = { $0.rpcURL() }
        var customSnapshot: @Sendable () -> CustomNetworkSnapshot = { CustomNetworkCache.shared.snapshot() }
        var freshCustomSnapshot: @Sendable () -> CustomNetworkSnapshotLoadResult = { CustomNetworkCache.shared.refreshSnapshot() }
        var definitionResult: @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult = Self.customDefinitionResult
        var insertNetwork: @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult = SharedDefaults.insertNetwork
        var invalidateCache: @Sendable () -> Void = { CustomNetworkCache.shared.invalidate() }
        var fileIO: ExtensionRequestStoreFiles.IO?
        var clock: @Sendable () -> Date = Date.init
        var monotonicClock: @Sendable () -> ContinuousClock.Instant = { .now }
        var hooks: AuthorityExecutionHooks = .none

        private static func customDefinitionResult(_ network: EthereumNetworkFromDapp) -> CustomNetworkInsertionResult {
            guard let chainID = Int(hexString: network.chainId),
                  let entry = CustomNetworkCache.shared.snapshot().entriesByChainId[chainID] else { return .unavailable }
            let urls = CustomNetworkDefinition.requestedRPCURLs(for: network)
            guard !urls.isEmpty else { return .unavailable }
            return urls.contains {
                CustomNetworkDefinition.matches(requested: network, requestedRPCURL: $0, existing: entry.definition, existingRPCURL: entry.rpcURL)
            } ? .matching : .conflict
        }
    }

    let configuration: AuthorityRuntimeConfiguration
    let dependencies: Dependencies
    let networks: NetworkResolver
    let store: ExtensionRequestFileStore
    let requests: ExtensionBridge

    init(configuration: AuthorityRuntimeConfiguration, dependencies: Dependencies = .init()) {
        self.configuration = configuration
        self.dependencies = dependencies
        let networks = NetworkResolver(
            catalog: configuration.catalog, catalogOwnedChainIds: configuration.catalogOwnedChainIds,
            decodedChainIds: configuration.decodedChainIds, catalogURLBuilder: dependencies.catalogURLBuilder,
            customSnapshot: dependencies.customSnapshot, freshCustomSnapshot: dependencies.freshCustomSnapshot
        )
        self.networks = networks
        let definitionResult = dependencies.definitionResult
        let insertNetwork = dependencies.insertNetwork
        let store = ExtensionRequestFileStore(containerURL: configuration.storage.containerURL, dependencies: .init(
            messages: configuration.messages, clock: dependencies.clock, fileIO: dependencies.fileIO,
            completeChainAddition: { permit in
                EthereumDappRequestProcessor.completeApprovedChainAddition(
                    permit: permit, networkResolver: networks.resolution,
                    customDefinitionResult: definitionResult, insertNetwork: insertNetwork
                )
            },
            resolveImmediate: { resolution, request in
                resolution.response(for: request, networkResolver: networks.resolution, customDefinitionResult: definitionResult)
            }
        ))
        self.store = store
        requests = ExtensionBridge(store: store, hooks: dependencies.hooks)
    }

    func makeRequestProcessor(solanaEndpoints: any SolanaEndpointResolving) -> DappRequestProcessor {
        DappRequestProcessor(ethereumNetworkResolver: networks.approvalResolution,
            selectionNetworkResolver: networks.network, customDefinitionResult: dependencies.definitionResult,
            solanaEndpoints: solanaEndpoints)
    }
}
