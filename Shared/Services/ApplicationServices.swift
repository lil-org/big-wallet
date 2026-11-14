import Foundation
import WalletDomain
import WalletAuthority
import WalletFlows
import WalletNetworking

@MainActor
final class ApplicationServices {
    static let shared = ApplicationServices()

    private let runtime: AuthorityRuntime
    let authorization: any AlchemyAuthorizationProviding
    let prices: PriceService
#if os(macOS)
    let ethereum: EthereumTransactionPreparation
    let runtimeIdentityDirectoryURL: URL?
#endif
    var wallets: WalletsManager { runtime.wallets }
    var metadata: WalletsMetadataService { runtime.metadata }
    var credentials: WalletCredentials { runtime.credentials }
    var requests: ExtensionBridge { runtime.requests }
    var networks: NetworkResolver { runtime.networks }
    var messages: AuthorityMessages { runtime.messages }
    lazy var access = WalletAccessController(credentials: credentials)

    private init() {
        let configuration = RuntimeResources.configuration()
#if BW_SAFARI_VM_TESTING
        let fixtures = SafariVMFixtures.shared
        let services = SafariVMApplicationServices.make(configuration: configuration)
        runtime = services.runtime
        authorization = services.authorization
        prices = services.prices
#if os(macOS)
        ethereum = services.ethereum
        runtimeIdentityDirectoryURL = fixtures.isLocal
            ? fixtures.root.appendingPathComponent("native-runtime-identities-v1", isDirectory: true)
            : AmbientRuntimeIdentity.defaultDirectoryURL
#endif
#else
        let authorization = AlchemyJWTProvider.live(bundle: .main, containerURL: configuration.storage.containerURL)
        self.authorization = authorization
        prices = PriceService(urlSession: WalletHTTPSession.make())
#if os(macOS)
        runtimeIdentityDirectoryURL = AmbientRuntimeIdentity.defaultDirectoryURL
        let rpc = EthereumRPC(authorizationProvider: authorization)
        let inspector = TransactionInspector()
        ethereum = EthereumTransactionPreparation(rpc: rpc, interpretTransaction: inspector.interpret)
        let solana = SolanaRPCClient(urlSession: WalletHTTPSession.make(), authorizationProvider: authorization,
            messages: .init(failedToSend: Strings.failedToSend, blockhashNotFound: Strings.solanaBlockhashNotFound))
        runtime = AuthorityRuntime.live(configuration: configuration,
            solanaEndpoints: SolanaRPCClient.RPCConfiguration.bundled,
            broadcaster: SignedBroadcastClient(ethereum: EthereumBroadcastClient(rpc: rpc), solana: solana))
#else
        runtime = AuthorityRuntime.live(configuration: configuration)
#endif
#endif
    }

    func prewarm() {
        guard let authorization = authorization as? AlchemyJWTProvider else { return }
        AlchemyJWTProvider.prewarmForApplicationLifecycle(provider: { authorization })
    }

    func recordReviewRequest(at date: Date) { runtime.recordReviewRequest(at: date) }
    func invalidateNetworkCache() { runtime.invalidateNetworkCache() }

#if os(macOS)
    func makeNativeApprovalCoordinator(handle: RequestHandle, nativeDeliveryNonce: NativeDeliveryNonce) -> NativeApprovalCoordinator {
        NativeApprovalCoordinator(authority: runtime.makeNativeApprovalAuthority(handle: handle, nativeDeliveryNonce: nativeDeliveryNonce))
    }
#else
    func startVaultReconciliation(backgroundTask: @escaping AuthorityRuntime.BackgroundTask,
                                  protectedDataDidBecomeAvailable: Notification.Name) async {
        await runtime.startVaultReconciliation(backgroundTask: backgroundTask, protectedDataDidBecomeAvailable: protectedDataDidBecomeAvailable)
    }

    func reconcileVault() async { await runtime.reconcileVault() }
    func waitForVaultReconciliation() async { await runtime.waitForVaultReconciliation() }

#if BW_SAFARI_VM_TESTING
    func invalidateVaultForTesting() async throws { try await SafariVMApplicationServices.invalidateVault(runtime) }
#endif
#endif
}
