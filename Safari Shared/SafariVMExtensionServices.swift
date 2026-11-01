import WalletDomain
import WalletNetworking
#if BW_SAFARI_VM_TESTING
@testable import WalletAuthority
import Foundation

@MainActor
struct SafariVMExtensionServices {
    let safariRPC: SafariRPCClient
#if os(macOS)
    let authority: NativeTransportRuntime
#else
    let authority: PopupAuthorityRuntime
    let ethereum: EthereumTransactionPreparation
    let prices: PriceService
#endif

    static func make(configuration: AuthorityRuntimeConfiguration) -> SafariVMExtensionServices {
        let environment = SafariVMRuntimeEnvironment(configuration: configuration)
        let authorization = SafariVMRPCFixtureAuthorization()
        let safariRPC = SafariRPCClient(urlSession: WalletHTTPSession.make(), authorizationProvider: authorization,
            authorizeRequest: environment.routing.authorize)
#if os(macOS)
        let authority = NativeTransportRuntime(composition: environment.composition,
            solanaEndpoints: SolanaRPCClient.RPCConfiguration.bundled)
        return SafariVMExtensionServices(safariRPC: safariRPC, authority: authority)
#else
        let rpc = EthereumRPC(authorizationProvider: authorization, authorizeRequest: environment.routing.authorize)
        let ethereum = EthereumTransactionPreparation(rpc: rpc, interpretTransaction: { _ in nil })
        let solana = SolanaRPCClient(urlSession: WalletHTTPSession.make(), authorizationProvider: authorization,
            messages: .init(failedToSend: Strings.failedToSend, blockhashNotFound: Strings.solanaBlockhashNotFound),
            authorizeRequest: environment.routing.authorize)
        var dependencies = PopupAuthorityRuntime.Dependencies()
        dependencies.makeVault = { _, _ in environment.vault() }
        dependencies.makeMetadata = environment.metadata
        let authority = PopupAuthorityRuntime(composition: environment.composition,
            solanaEndpoints: SolanaRPCClient.RPCConfiguration.bundled,
            broadcaster: SignedBroadcastClient(ethereum: EthereumBroadcastClient(rpc: rpc), solana: solana),
            preparation: ethereum.makePreparationOperations(), dependencies: dependencies)
        return SafariVMExtensionServices(safariRPC: safariRPC, authority: authority,
            ethereum: ethereum, prices: PriceService(fetchPrices: { ["ETH": 2_000] }))
#endif
    }
}
#endif
