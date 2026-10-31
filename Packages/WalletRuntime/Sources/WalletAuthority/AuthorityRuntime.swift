import Foundation
import WalletDomain

public struct AuthorityStorageConfiguration: Sendable {
    public let containerURL: URL?

    public init(containerURL: URL?) {
        self.containerURL = containerURL
    }

    public static var application: AuthorityStorageConfiguration {
        AuthorityStorageConfiguration(containerURL: SharedDefaults.containerURL)
    }
}

@MainActor
public final class AuthorityRuntime {
    public enum ErrorKind: Sendable {
        case userRejected, internalError, approvalInterrupted, privateBrowsingUnsupported
    }

    public let wallets: WalletsManager
    public let credentials: WalletCredentials
    public let requests: ExtensionBridge
    public let admission: DappRequestAdmission
    public let networks: NetworkResolver
    public let messages: AuthorityMessages
    public let metadata: WalletsMetadataService

    private final class NativeAuthorityReference {
        weak var value: NativeApprovalAuthority?
        init(_ value: NativeApprovalAuthority) { self.value = value }
    }

    private var nativeAuthorities = [ApprovalRouteKey: NativeAuthorityReference]()
    private let processor: DappRequestProcessor
    private let finalizer: NativeApprovalFinalizer
    private let executionEnvironment: DurableApprovalExecutor.Environment
    private let preparation: TransactionApprovalOperations
    private let vault: SafariApprovalVault
    private let authorityID: UUID
    private nonisolated let clock: @Sendable () -> Date
    private let monotonicClock: @Sendable () -> ContinuousClock.Instant
    private let hooks: AuthorityExecutionHooks
    private let definitionResult: @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult
    private nonisolated let invalidateCache: @Sendable () -> Void
#if os(iOS) || os(visionOS)
    private let vaultHost: SafariApprovalVaultHost
#endif

    public static func live(
        catalog: NetworkCatalog?,
        catalogOwnedChainIds: Set<Int>,
        decodedChainIds: Set<Int> = [],
        solanaEndpoints: any SolanaEndpointResolving,
        broadcaster: any SignedTransactionBroadcasting,
        preparation: TransactionApprovalOperations,
        storage: AuthorityStorageConfiguration,
        messages: AuthorityMessages
    ) -> AuthorityRuntime {
        configured(
            catalog: catalog, catalogOwnedChainIds: catalogOwnedChainIds, decodedChainIds: decodedChainIds,
            broadcaster: broadcaster, preparation: preparation, solanaEndpoints: solanaEndpoints, storage: storage, messages: messages,
            keychain: Keychain()
        )
    }

    static func testing(
        catalog: NetworkCatalog?,
        catalogOwnedChainIds: Set<Int>,
        decodedChainIds: Set<Int> = [],
        solanaEndpoints: any SolanaEndpointResolving,
        broadcaster: any SignedTransactionBroadcasting,
        preparation: TransactionApprovalOperations,
        storage: AuthorityStorageConfiguration,
        messages: AuthorityMessages,
        keychain: Keychain,
        metadata: WalletsMetadataService,
        vault: SafariApprovalVault,
        integrityKeyStore: any SafariApprovalIntegrityKeyStoring,
        vaultHostDefaults: any SharedPreferenceStorage = UserDefaultsPreferenceStorage.standard,
        catalogURLBuilder: (NetworkCatalogRecord) -> URL? = { $0.rpcURL() },
        customSnapshot: @escaping @Sendable () -> CustomNetworkSnapshot,
        freshCustomSnapshot: @escaping @Sendable () -> CustomNetworkSnapshotLoadResult,
        definitionResult: @escaping @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult,
        insertNetwork: @escaping @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult,
        invalidateCache: @escaping @Sendable () -> Void = {},
        fileIO: ExtensionRequestStoreFiles.IO? = nil,
        metadataMutations: WalletRepository.MetadataMutations? = nil,
        notifications: WalletStoreChangeNotifications = .live,
        credentialAuthentication: WalletCredentialAuthentication = .live,
        clock: @escaping @Sendable () -> Date = Date.init,
        monotonicClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        hooks: AuthorityExecutionHooks = .none
    ) -> AuthorityRuntime {
        configured(
            catalog: catalog, catalogOwnedChainIds: catalogOwnedChainIds, decodedChainIds: decodedChainIds,
            broadcaster: broadcaster, preparation: preparation, solanaEndpoints: solanaEndpoints, storage: storage, messages: messages,
            keychain: keychain, metadata: metadata, vault: vault, integrityKeyStore: integrityKeyStore, vaultHostDefaults: vaultHostDefaults,
            catalogURLBuilder: catalogURLBuilder, customSnapshot: customSnapshot,
            freshCustomSnapshot: freshCustomSnapshot, definitionResult: definitionResult,
            insertNetwork: insertNetwork, invalidateCache: invalidateCache, fileIO: fileIO,
            metadataMutations: metadataMutations, notifications: notifications,
            credentialAuthentication: credentialAuthentication, clock: clock, monotonicClock: monotonicClock, hooks: hooks
        )
    }

    private static func configured(
        catalog: NetworkCatalog?,
        catalogOwnedChainIds: Set<Int>,
        decodedChainIds: Set<Int>,
        broadcaster: any SignedTransactionBroadcasting,
        preparation: TransactionApprovalOperations,
        solanaEndpoints: any SolanaEndpointResolving,
        storage: AuthorityStorageConfiguration,
        messages: AuthorityMessages,
        keychain: Keychain,
        metadata suppliedMetadata: WalletsMetadataService? = nil,
        vault suppliedVault: SafariApprovalVault? = nil,
        integrityKeyStore: any SafariApprovalIntegrityKeyStoring = SafariApprovalIntegrityKeychainStore(),
        vaultHostDefaults: any SharedPreferenceStorage = UserDefaultsPreferenceStorage.standard,
        catalogURLBuilder: (NetworkCatalogRecord) -> URL? = { $0.rpcURL() },
        customSnapshot: @escaping @Sendable () -> CustomNetworkSnapshot = { CustomNetworkCache.shared.snapshot() },
        freshCustomSnapshot: @escaping @Sendable () -> CustomNetworkSnapshotLoadResult = { CustomNetworkCache.shared.refreshSnapshot() },
        definitionResult: @escaping @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult = customDefinitionResult,
        insertNetwork: @escaping @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult = SharedDefaults.insertNetwork,
        invalidateCache: @escaping @Sendable () -> Void = { CustomNetworkCache.shared.invalidate() },
        fileIO: ExtensionRequestStoreFiles.IO? = nil,
        metadataMutations: WalletRepository.MetadataMutations? = nil,
        notifications: WalletStoreChangeNotifications = .live,
        credentialAuthentication: WalletCredentialAuthentication = .live,
        clock: @escaping @Sendable () -> Date = Date.init,
        monotonicClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        hooks: AuthorityExecutionHooks = .none
    ) -> AuthorityRuntime {
        let networks = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: catalogOwnedChainIds,
            decodedChainIds: decodedChainIds,
            catalogURLBuilder: catalogURLBuilder,
            customSnapshot: customSnapshot,
            freshCustomSnapshot: freshCustomSnapshot
        )
        let store = ExtensionRequestFileStore(
            containerURL: storage.containerURL,
            dependencies: .init(
                messages: messages,
                clock: clock,
                fileIO: fileIO,
                completeChainAddition: { permit in
                    EthereumDappRequestProcessor.completeApprovedChainAddition(
                        permit: permit,
                        networkResolver: networks.resolution,
                        customDefinitionResult: definitionResult,
                        insertNetwork: insertNetwork
                    )
                },
                resolveImmediate: { resolution, request in
                    resolution.response(
                        for: request,
                        networkResolver: networks.resolution,
                        customDefinitionResult: definitionResult
                    )
                }
            )
        )
        let authorityID = UUID()
        let metadata = suppliedMetadata ?? WalletsMetadataService.live()
        let wallets = WalletsManager(keychain: keychain, reloadMetadata: { metadata.reload() }, walletSourceMutator: store,
            notifications: notifications, metadataMutations: metadataMutations ?? metadata.mutations, authorityID: authorityID, clock: monotonicClock)
        let requests = ExtensionBridge(store: store, hooks: hooks)
        let vault = suppliedVault ?? SafariApprovalVault(
            fileURL: storage.containerURL?.appendingPathComponent("SafariApprovalVault.v1", isDirectory: false),
            clock: clock, hooks: hooks
        )
#if os(iOS) || os(visionOS)
        let repository = wallets.repository
        let vaultHost = SafariApprovalVaultHost(vault: vault, defaults: vaultHostDefaults, integrityKeyStore: integrityKeyStore) {
            try await repository.safariApprovalSourceSnapshot()
        }
        wallets.approvalVaultHost = vaultHost
        let credentials = WalletCredentials(keychain: keychain, messages: messages, authorityID: authorityID, vaultHost: vaultHost, authentication: credentialAuthentication, accessClock: monotonicClock, postCreation: notifications.postMutation)
#else
        let credentials = WalletCredentials(keychain: keychain, messages: messages, authorityID: authorityID, authentication: credentialAuthentication, accessClock: monotonicClock, postCreation: notifications.postMutation)
#endif
        let processor = DappRequestProcessor(
            ethereumNetworkResolver: networks.approvalResolution,
            selectionNetworkResolver: networks.network,
            customDefinitionResult: definitionResult,
            solanaEndpoints: solanaEndpoints
        )
        let environment = DurableApprovalExecutor.Environment(requestProcessor: processor, broadcaster: broadcaster, hooks: hooks, clock: clock)
        let finalizer = NativeApprovalFinalizer(
            store: requests,
            executionEnvironment: environment,
            refreshWalletCatalog: {
                guard await wallets.start() else { return nil }
                return wallets.reviewCatalog()
            },
            makeSigningPreparation: { scope in
                WalletSigningPreparation.fromSource(scope: scope, walletsManager: wallets, clock: clock)
            },
            networkResolver: networks.approvalResolution,
            customDefinitionResult: definitionResult
        )
#if os(iOS) || os(visionOS)
        let admissionCatalog: (() async -> WalletReviewCatalog?)? = {
            await awaitBackgroundOperation { vault.reviewCatalog() } ?? nil
        }
#else
        let admissionCatalog: (() async -> WalletReviewCatalog?)? = nil
#endif
        let admission = DappRequestAdmission(
            store: requests,
            requestProcessor: processor,
            reviewCatalog: admissionCatalog,
            messages: messages
        )
        return AuthorityRuntime(
            wallets: wallets, credentials: credentials, requests: requests,
            admission: admission, networks: networks, messages: messages, metadata: metadata,
            processor: processor, finalizer: finalizer, executionEnvironment: environment,
            preparation: preparation, vault: vault, authorityID: authorityID,
            definitionResult: definitionResult, invalidateCache: invalidateCache, clock: clock, monotonicClock: monotonicClock, hooks: hooks
        )
    }

    private init(
        wallets: WalletsManager,
        credentials: WalletCredentials,
        requests: ExtensionBridge,
        admission: DappRequestAdmission,
        networks: NetworkResolver,
        messages: AuthorityMessages,
        metadata: WalletsMetadataService,
        processor: DappRequestProcessor,
        finalizer: NativeApprovalFinalizer,
        executionEnvironment: DurableApprovalExecutor.Environment,
        preparation: TransactionApprovalOperations,
        vault: SafariApprovalVault,
        authorityID: UUID,
        definitionResult: @escaping @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult,
        invalidateCache: @escaping @Sendable () -> Void,
        clock: @escaping @Sendable () -> Date,
        monotonicClock: @escaping @Sendable () -> ContinuousClock.Instant,
        hooks: AuthorityExecutionHooks
    ) {
        self.wallets = wallets
        self.credentials = credentials
        self.requests = requests
        self.admission = admission
        self.networks = networks
        self.messages = messages
        self.metadata = metadata
        self.processor = processor
        self.finalizer = finalizer
        self.executionEnvironment = executionEnvironment
        self.preparation = preparation
        self.vault = vault
        self.authorityID = authorityID
        self.clock = clock
        self.monotonicClock = monotonicClock
        self.hooks = hooks
        self.definitionResult = definitionResult
        self.invalidateCache = invalidateCache
#if os(iOS) || os(visionOS)
        self.vaultHost = wallets.approvalVaultHost
#endif
    }

    public func makeNativeApprovalAuthority(
        handle: RequestHandle,
        nativeDeliveryNonce: NativeDeliveryNonce
    ) -> NativeApprovalAuthority {
        for key in Array(nativeAuthorities.keys) where nativeAuthorities[key]?.value == nil {
            nativeAuthorities.removeValue(forKey: key)
        }
        let key = ApprovalRouteKey(handle: handle, nativeDeliveryNonce: nativeDeliveryNonce)
        if let current = nativeAuthorities[key]?.value { return current }
        let authority = NativeApprovalAuthority(
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce,
            store: requests,
            environment: .live(processor: processor, wallets: wallets, finalizer: finalizer, messages: messages,
                authorityID: authorityID, clock: clock, monotonicClock: monotonicClock, hooks: hooks)
        )
        nativeAuthorities[key] = NativeAuthorityReference(authority)
        return authority
    }

    public func makePopupApprovalAuthority(
        approvalSubjectTitle: @escaping @MainActor @Sendable (ApprovalSubject) -> String,
        loadTransactionContext: @escaping @MainActor @Sendable (SendTransactionAction) async -> String?
    ) -> PopupApprovalAuthority {
        PopupApprovalAuthority(
            store: requests,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { [vault] in
                    await awaitBackgroundOperation { vault.reviewCatalog() } ?? nil
                },
                approvalCatalog: { [vault] in
                    await awaitBackgroundOperation { vault.approvalCatalog() } ?? nil
                },
                unlockWallets: { await self.vault.unlockResult(reason: $0, scope: $1) },
                reloadMetadata: { self.metadata.reload() }
            ),
            loadsTransactionContext: true,
            transactionApprovalOperations: preparation,
            invalidateNetworkCache: invalidateCache,
            selectionNetworkResolver: { self.networks.network(chainIdHex: $0) },
            approvalNetworkResolver: networks.approvalResolution,
            executionEnvironment: executionEnvironment,
            approvalSubjectTitle: approvalSubjectTitle,
            customDefinitionResult: definitionResult,
            messages: messages,
            loadTransactionContext: loadTransactionContext
        )
    }

    public func error(_ kind: ErrorKind) -> ProviderResponseError {
        AuthorityMessageContext.$current.withValue(messages) {
            switch kind {
            case .userRejected: .userRejected
            case .internalError: .internalError
            case .approvalInterrupted: .approvalInterrupted
            case .privateBrowsingUnsupported: .privateBrowsingUnsupported
            }
        }
    }

    nonisolated public func invalidateNetworkCache() {
        invalidateCache()
    }

    public func recordReviewRequest(at date: Date) {
        Defaults.latestReviewRequestDate = date
    }

#if os(iOS) || os(visionOS)
    public typealias BackgroundTask = @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)?

    public func startVaultReconciliation(
        backgroundTask: @escaping BackgroundTask,
        protectedDataDidBecomeAvailable: Notification.Name
    ) async {
        await vaultHost.start(backgroundTask: backgroundTask, protectedDataDidBecomeAvailable: protectedDataDidBecomeAvailable)
    }

    public func reconcileVault() async {
        await vaultHost.reconcile()
    }

    public func waitForVaultReconciliation() async {
        await vaultHost.waitForReconciliation()
    }

    func invalidateVaultForTesting() async throws {
        try await vaultHost.performSourceMutation { invalidate in try invalidate() }
        await vaultHost.waitForReconciliation()
    }
#endif

    nonisolated private static func customDefinitionResult(_ network: EthereumNetworkFromDapp) -> CustomNetworkInsertionResult {
        guard let chainID = Int(hexString: network.chainId),
              let entry = CustomNetworkCache.shared.snapshot().entriesByChainId[chainID] else { return .unavailable }
        let urls = CustomNetworkDefinition.requestedRPCURLs(for: network)
        guard !urls.isEmpty else { return .unavailable }
        return urls.contains {
            CustomNetworkDefinition.matches(requested: network, requestedRPCURL: $0, existing: entry.definition, existingRPCURL: entry.rpcURL)
        } ? .matching : .conflict
    }
}
