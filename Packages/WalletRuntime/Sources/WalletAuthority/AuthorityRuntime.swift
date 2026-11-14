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
struct WalletManagementServices {
    struct Dependencies {
        var makeKeychain: @MainActor () -> Keychain = { Keychain() }
        var makeMetadata: @MainActor () -> WalletsMetadataService = { .live() }
        var metadataMutations: WalletRepository.MetadataMutations?
        var notifications: WalletStoreChangeNotifications = .live
        var credentialAuthentication: WalletCredentialAuthentication = .live
#if os(iOS) || os(visionOS)
        var makeVault: @MainActor (AuthorityRuntimeConfiguration, AuthorityComposition.Dependencies) -> SafariApprovalVault = {
            SafariApprovalVault(fileURL: $0.storage.containerURL?.appendingPathComponent("SafariApprovalVault.v1"),
                clock: $1.clock, hooks: $1.hooks)
        }
        var makeIntegrityKeyStore: @MainActor () -> any SafariApprovalIntegrityKeyStoring = { SafariApprovalIntegrityKeychainStore() }
        var vaultHostDefaults: any SharedPreferenceStorage = UserDefaultsPreferenceStorage.standard
#endif
    }

    let wallets: WalletsManager
    let credentials: WalletCredentials
    let metadata: WalletsMetadataService
    let authorityID: UUID
#if os(iOS) || os(visionOS)
    let vaultHost: SafariApprovalVaultHost
#endif

    init(composition: AuthorityComposition, dependencies: Dependencies) {
        let authorityID = UUID()
        self.authorityID = authorityID
        let keychain = dependencies.makeKeychain()
        let metadata = dependencies.makeMetadata()
        self.metadata = metadata
        let wallets = WalletsManager(keychain: keychain, reloadMetadata: { metadata.reload() },
            walletSourceMutator: composition.store, notifications: dependencies.notifications,
            metadataMutations: dependencies.metadataMutations ?? metadata.mutations,
            authorityID: authorityID, clock: composition.dependencies.monotonicClock)
        self.wallets = wallets
#if os(iOS) || os(visionOS)
        let vault = dependencies.makeVault(composition.configuration, composition.dependencies)
        let vaultHost = SafariApprovalVaultHost(vault: vault, defaults: dependencies.vaultHostDefaults,
            integrityKeyStore: dependencies.makeIntegrityKeyStore(), sourceSnapshot: wallets.makeSafariApprovalSourceReader())
        self.vaultHost = vaultHost
        wallets.approvalVaultHost = vaultHost
        credentials = WalletCredentials(keychain: keychain, messages: composition.configuration.messages,
            authorityID: authorityID, vaultHost: vaultHost, authentication: dependencies.credentialAuthentication,
            accessClock: composition.dependencies.monotonicClock, postCreation: dependencies.notifications.postMutation)
#else
        credentials = WalletCredentials(keychain: keychain, messages: composition.configuration.messages,
            authorityID: authorityID, authentication: dependencies.credentialAuthentication,
            accessClock: composition.dependencies.monotonicClock, postCreation: dependencies.notifications.postMutation)
#endif
    }
}

@MainActor
@available(iOSApplicationExtension, unavailable)
@available(macOSApplicationExtension, unavailable)
@available(visionOSApplicationExtension, unavailable)
public final class AuthorityRuntime {
    public enum ErrorKind: Sendable {
        case userRejected, internalError, approvalInterrupted, privateBrowsingUnsupported
    }

    public let wallets: WalletsManager
    public let credentials: WalletCredentials
    public let requests: ExtensionBridge
    public let networks: NetworkResolver
    public let messages: AuthorityMessages
    public let metadata: WalletsMetadataService
    private nonisolated let invalidateCache: @Sendable () -> Void
#if os(macOS)
    private let nativeApprovals: ApplicationNativeApprovals
#else
    private let vaultHost: SafariApprovalVaultHost
#endif

#if os(macOS)
    public static func live(configuration: AuthorityRuntimeConfiguration,
                            solanaEndpoints: any SolanaEndpointResolving,
                            broadcaster: any SignedTransactionBroadcasting) -> AuthorityRuntime {
        AuthorityRuntime(composition: .init(configuration: configuration), management: .init(),
            solanaEndpoints: solanaEndpoints, broadcaster: broadcaster)
    }

    init(composition: AuthorityComposition, management: WalletManagementServices.Dependencies,
         solanaEndpoints: any SolanaEndpointResolving, broadcaster: any SignedTransactionBroadcasting) {
        let management = WalletManagementServices(composition: composition, dependencies: management)
        wallets = management.wallets
        credentials = management.credentials
        metadata = management.metadata
        requests = composition.requests
        networks = composition.networks
        messages = composition.configuration.messages
        invalidateCache = composition.dependencies.invalidateCache
        nativeApprovals = ApplicationNativeApprovals(composition: composition, management: management,
            solanaEndpoints: solanaEndpoints, broadcaster: broadcaster)
    }

    public func makeNativeApprovalAuthority(handle: RequestHandle, nativeDeliveryNonce: NativeDeliveryNonce) -> NativeApprovalAuthority {
        nativeApprovals.makeAuthority(handle: handle, nativeDeliveryNonce: nativeDeliveryNonce)
    }
#else
    public static func live(configuration: AuthorityRuntimeConfiguration) -> AuthorityRuntime {
        AuthorityRuntime(composition: .init(configuration: configuration), management: .init())
    }

    init(composition: AuthorityComposition, management: WalletManagementServices.Dependencies) {
        let management = WalletManagementServices(composition: composition, dependencies: management)
        wallets = management.wallets
        credentials = management.credentials
        metadata = management.metadata
        requests = composition.requests
        networks = composition.networks
        messages = composition.configuration.messages
        invalidateCache = composition.dependencies.invalidateCache
        vaultHost = management.vaultHost
    }
#endif

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

    nonisolated public func invalidateNetworkCache() { invalidateCache() }

    public func recordReviewRequest(at date: Date) { Defaults.latestReviewRequestDate = date }

#if os(iOS) || os(visionOS)
    public typealias BackgroundTask = @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)?

    public func startVaultReconciliation(backgroundTask: @escaping BackgroundTask,
                                         protectedDataDidBecomeAvailable: Notification.Name) async {
        await vaultHost.start(backgroundTask: backgroundTask, protectedDataDidBecomeAvailable: protectedDataDidBecomeAvailable)
    }

    public func reconcileVault() async { await vaultHost.reconcile() }
    public func waitForVaultReconciliation() async { await vaultHost.waitForReconciliation() }

    func invalidateVaultForTesting() async throws {
        try await vaultHost.performSourceMutation { invalidate in try invalidate() }
        await vaultHost.waitForReconciliation()
    }
#endif
}

#if os(macOS)
@MainActor
private final class ApplicationNativeApprovals {
    private final class Reference {
        weak var value: NativeApprovalAuthority?
        init(_ value: NativeApprovalAuthority) { self.value = value }
    }

    private var authorities = [ApprovalRouteKey: Reference]()
    private let composition: AuthorityComposition
    private let management: WalletManagementServices
    private let processor: DappRequestProcessor
    private let finalizer: NativeApprovalFinalizer

    init(composition: AuthorityComposition, management: WalletManagementServices,
         solanaEndpoints: any SolanaEndpointResolving, broadcaster: any SignedTransactionBroadcasting) {
        self.composition = composition
        self.management = management
        let processor = composition.makeRequestProcessor(solanaEndpoints: solanaEndpoints)
        self.processor = processor
        let wallets = management.wallets
        let clock = composition.dependencies.clock
        finalizer = NativeApprovalFinalizer(store: composition.requests,
            executionEnvironment: .init(requestProcessor: processor, broadcaster: broadcaster,
                hooks: composition.dependencies.hooks, clock: clock),
            refreshWalletCatalog: {
                guard await wallets.start() else { return nil }
                return wallets.reviewCatalog()
            },
            makeSigningPreparation: { WalletSigningPreparation.fromSource(scope: $0, walletsManager: wallets, clock: clock) },
            networkResolver: composition.networks.approvalResolution,
            customDefinitionResult: composition.dependencies.definitionResult)
    }

    func makeAuthority(handle: RequestHandle, nativeDeliveryNonce: NativeDeliveryNonce) -> NativeApprovalAuthority {
        authorities = authorities.filter { $0.value.value != nil }
        let key = ApprovalRouteKey(handle: handle, nativeDeliveryNonce: nativeDeliveryNonce)
        if let current = authorities[key]?.value { return current }
        let authority = NativeApprovalAuthority(handle: handle, nativeDeliveryNonce: nativeDeliveryNonce,
            store: composition.requests,
            environment: .live(processor: processor, wallets: management.wallets, finalizer: finalizer,
                messages: composition.configuration.messages, authorityID: management.authorityID,
                clock: composition.dependencies.clock, monotonicClock: composition.dependencies.monotonicClock,
                hooks: composition.dependencies.hooks))
        authorities[key] = Reference(authority)
        return authority
    }
}
#endif
