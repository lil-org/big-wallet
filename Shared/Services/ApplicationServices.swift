import Foundation
import WalletDomain
import WalletAuthority
import WalletFlows
import WalletNetworking

@MainActor
final class ApplicationServices {
    static let shared = ApplicationServices()

    let authority: WalletAuthoritySystem
    let authorization: any AlchemyAuthorizationProviding
    let prices: PriceService
#if os(macOS)
    let ethereum: EthereumTransactionPreparation
    let runtimeIdentityDirectoryURL: URL?
#endif
#if BW_SAFARI_VM_TESTING
    let fixtureRuntime: AuthorityRuntime
#endif

    var wallets: WalletsManager { authority.wallets }
    var metadata: WalletsMetadataService { authority.metadata }
    var credentials: WalletCredentials { authority.credentials }
    var requests: ExtensionBridge { authority.requests }
    var networks: NetworkResolver { authority.networks }
    lazy var access = WalletAccessController(credentials: credentials)

    private init() {
        let configuration = RuntimeResources.configuration()
#if BW_SAFARI_VM_TESTING
        let fixtures = SafariVMFixtures.shared
        let services = SafariVMApplicationServices.make(configuration: configuration)
        authority = services.authority
        fixtureRuntime = services.runtime
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
        authority = WalletAuthoritySystem.live(configuration: configuration,
            solanaEndpoints: SolanaRPCClient.RPCConfiguration.bundled,
            broadcaster: SignedBroadcastClient(ethereum: EthereumBroadcastClient(rpc: rpc), solana: solana))
#else
        authority = WalletAuthoritySystem.live(configuration: configuration)
#endif
#endif
    }

    func prewarm() {
        guard let authorization = authorization as? AlchemyJWTProvider else { return }
        AlchemyJWTProvider.prewarmForApplicationLifecycle(provider: { authorization })
    }
}
