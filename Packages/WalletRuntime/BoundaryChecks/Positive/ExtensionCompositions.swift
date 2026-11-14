import WalletDomain
import WalletAuthority

@MainActor
func extensionCompositions(configuration: AuthorityRuntimeConfiguration, endpoints: any SolanaEndpointResolving,
    broadcaster: any SignedTransactionBroadcasting, preparation: TransactionApprovalOperations) {
    _ = NativeTransportRuntime.live(configuration: configuration, solanaEndpoints: endpoints)
    _ = PopupAuthorityRuntime.live(configuration: configuration, solanaEndpoints: endpoints,
        broadcaster: broadcaster, preparation: preparation)
}
