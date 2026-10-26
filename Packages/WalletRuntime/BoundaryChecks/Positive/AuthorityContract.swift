import Foundation
import WalletDomain
import WalletAuthority

@MainActor
func authorityContract(system: WalletAuthoritySystem, wallet: WalletSnapshot, review: NativeApprovalReview,
    handle: RequestHandle, nonce: NativeDeliveryNonce, transaction: Transaction, network: ResolvedEthereumNetwork,
    grant: WalletAuthenticationGrant, access: WalletAccessSession) async throws {
    let credentials = system.credentials
    let challenge = credentials.makeWalletAccessChallenge()
    _ = try credentials.verify(password: "fixture", challenge: challenge)
    _ = credentials.accessSession(authorization: grant)
    _ = credentials.isCurrent(access)
    let coordinator = system.makeNativeApprovalCoordinator(handle: handle, nativeDeliveryNonce: nonce)
    coordinator.resumeAfterAuthentication(authorization: access)
    _ = review.makeMessageAuthenticationChallenge(solanaCluster: nil)
    _ = review.makeTransactionAuthenticationChallenge(transaction: transaction, reviewedNetwork: network)
    coordinator.approveMessage(solanaCluster: nil, review: review, authorization: grant)
    coordinator.approveTransaction(transaction, reviewedNetwork: network, review: review, authorization: grant)
    _ = try await system.wallets.makeExportChallenge(wallet: wallet, kind: .mnemonic)
    _ = try await system.wallets.exportMnemonic(wallet: wallet, authorization: grant)
    _ = try await system.wallets.exportPrivateKey(wallet: wallet, authorization: grant)
    challenge.invalidate()
    grant.invalidate()
    access.invalidate()
}
