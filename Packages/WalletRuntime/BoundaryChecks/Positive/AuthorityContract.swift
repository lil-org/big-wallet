import Foundation
import WalletDomain
import WalletAuthority
import WalletFlows

@MainActor
func authorityContract(system: WalletAuthoritySystem, wallet: WalletSnapshot, review: NativeApprovalReview,
    handle: RequestHandle, nonce: NativeDeliveryNonce, transaction: Transaction, network: ResolvedEthereumNetwork,
    grant: WalletAuthenticationGrant, access: WalletAccessSession) async throws {
    let credentials = system.credentials
    let challenge = credentials.makeWalletAccessChallenge()
    _ = try credentials.verify(password: "fixture", challenge: challenge)
    _ = credentials.accessSession(authorization: grant)
    _ = credentials.validateAccess(access)
    _ = credentials.permitsAuthenticatedPresentation(access)
    let _: Duration? = credentials.recordInteraction(access)
    _ = credentials.remainingAccessLifetime(access)
#if os(macOS)
    let coordinator = system.makeNativeApprovalCoordinator(handle: handle, nativeDeliveryNonce: nonce)
    coordinator.resumeAfterAuthentication(authorization: access)
#endif
    _ = review.makeMessageAuthenticationChallenge(solanaCluster: nil)
    _ = review.makeTransactionAuthenticationChallenge(transaction: transaction, reviewedNetwork: network)
#if os(macOS)
    coordinator.approveMessage(solanaCluster: nil, review: review, authorization: grant)
    coordinator.approveTransaction(transaction, reviewedNetwork: network, review: review, authorization: grant)
#endif
    _ = try await system.wallets.makeExportChallenge(wallet: wallet, kind: .mnemonic)
    _ = try await system.wallets.exportMnemonic(wallet: wallet, authorization: grant)
    _ = try await system.wallets.exportPrivateKey(wallet: wallet, authorization: grant)
    _ = try await system.wallets.createWallet(access: access)
    _ = try await system.wallets.addWallet(input: "fixture", inputPassword: nil, access: access)
    try await system.wallets.update(wallet: wallet, enabledAccounts: wallet.accounts, access: access)
    try await system.wallets.delete(wallet: wallet, access: access)
    let preview = try await system.wallets.previewSession(wallet: wallet, access: access)
    _ = try await preview.previewAccounts(page: 0)
    preview.invalidate()
    challenge.invalidate()
    grant.invalidate()
    access.invalidate()
}

@MainActor
func transportRuntimeContract(configuration: AuthorityRuntimeConfiguration, endpoints: any SolanaEndpointResolving) {
    let runtime = NativeTransportRuntime.live(configuration: configuration, solanaEndpoints: endpoints)
    let _: ExtensionBridge = runtime.requests
    let _: DappRequestAdmission = runtime.admission
    let _: NetworkResolver = runtime.networks
    runtime.invalidateNetworkCache()
}

@MainActor
func popupRuntimeContract(configuration: AuthorityRuntimeConfiguration, endpoints: any SolanaEndpointResolving,
    broadcaster: any SignedTransactionBroadcasting, preparation: TransactionApprovalOperations, account: WalletAccount) {
    let runtime = PopupAuthorityRuntime.live(configuration: configuration, solanaEndpoints: endpoints,
        broadcaster: broadcaster, preparation: preparation)
    _ = runtime.accountName(walletID: "fixture", account: account)
    _ = runtime.makePopupApprovalAuthority(approvalSubjectTitle: { _ in "Approve" }, loadTransactionContext: { _ in nil })
}
