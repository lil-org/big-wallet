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
    let coordinator = system.makeNativeApprovalCoordinator(handle: handle, nativeDeliveryNonce: nonce)
    coordinator.resumeAfterAuthentication(authorization: access)
    _ = review.makeMessageAuthenticationChallenge(solanaCluster: nil)
    _ = review.makeTransactionAuthenticationChallenge(transaction: transaction, reviewedNetwork: network)
    coordinator.approveMessage(solanaCluster: nil, review: review, authorization: grant)
    coordinator.approveTransaction(transaction, reviewedNetwork: network, review: review, authorization: grant)
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
