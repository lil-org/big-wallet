import Foundation
import WalletDomain
import WalletAuthority
import WalletFlows
import WalletNetworking

@MainActor
final class SafariExtensionServices {
    static let shared = SafariExtensionServices()

    let safariRPC: SafariRPCClient
#if os(macOS)
    let authority: NativeTransportRuntime
    private let runtimeIdentityDirectoryURL: URL?
    lazy var nativeApprovals = NativeApprovalService(dependencies: .live(
        bridge: requests, runtimeIdentityDirectoryURL: runtimeIdentityDirectoryURL))
#else
    let authority: PopupAuthorityRuntime
    private let ethereum: EthereumTransactionPreparation
    private let prices: PriceService
    lazy var popupSessions: PopupRequestSessions = {
        let presentation = PopupPresentation.make(networks: networks, prices: prices,
            accountName: { [authority] in authority.accountName(walletID: $0, account: $1) })
        return PopupRequestSessions(authority: authority.makePopupApprovalAuthority(
            approvalSubjectTitle: { $0.title },
            loadTransactionContext: { [ethereum, prices] action in
                Task { await prices.update() }
                guard let balance = try? await ethereum.getBalance(network: action.chain, address: action.account.address) else { return nil }
                return balance.eth(shortest: true) + " " + action.chain.symbol
            }), presentation: presentation, messages: authority.messages)
    }()
#endif

    var requests: ExtensionBridge { authority.requests }
    var networks: NetworkResolver { authority.networks }

    private init() {
        let configuration = RuntimeResources.configuration()
#if BW_SAFARI_VM_TESTING
        let fixtures = SafariVMFixtures.shared
        let services = SafariVMExtensionServices.make(configuration: configuration)
        authority = services.authority
        safariRPC = services.safariRPC
#if os(macOS)
        runtimeIdentityDirectoryURL = fixtures.isLocal
            ? fixtures.root.appendingPathComponent("native-runtime-identities-v1", isDirectory: true)
            : AmbientRuntimeIdentity.defaultDirectoryURL
#else
        ethereum = services.ethereum
        prices = services.prices
#endif
#else
        let authorization = AlchemyJWTProvider.live(bundle: .main, containerURL: configuration.storage.containerURL)
        safariRPC = SafariRPCClient(urlSession: WalletHTTPSession.make(), authorizationProvider: authorization)
#if os(macOS)
        runtimeIdentityDirectoryURL = AmbientRuntimeIdentity.defaultDirectoryURL
        authority = NativeTransportRuntime.live(configuration: configuration,
            solanaEndpoints: SolanaRPCClient.RPCConfiguration.bundled)
#else
        let rpc = EthereumRPC(authorizationProvider: authorization)
        let inspector = TransactionInspector()
        let ethereum = EthereumTransactionPreparation(rpc: rpc, interpretTransaction: inspector.interpret)
        self.ethereum = ethereum
        prices = PriceService(urlSession: WalletHTTPSession.make())
        let solana = SolanaRPCClient(urlSession: WalletHTTPSession.make(), authorizationProvider: authorization,
            messages: .init(failedToSend: Strings.failedToSend, blockhashNotFound: Strings.solanaBlockhashNotFound))
        authority = PopupAuthorityRuntime.live(configuration: configuration,
            solanaEndpoints: SolanaRPCClient.RPCConfiguration.bundled,
            broadcaster: SignedBroadcastClient(ethereum: EthereumBroadcastClient(rpc: rpc), solana: solana),
            preparation: ethereum.makePreparationOperations())
#endif
#endif
    }
}
