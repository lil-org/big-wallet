import WalletDomain
import WalletStorageSupport
import Foundation

struct PopupWalletEnvironment: Sendable {

    let currentReviewCatalog: @MainActor @Sendable () async -> WalletReviewCatalog?
    let currentApprovalCatalog: @MainActor @Sendable () async -> WalletReviewCatalog?
    let unlock: @MainActor @Sendable (String, WalletSigningScope) async -> WalletUnlockResult

    nonisolated init(
        reviewCatalog: @escaping @MainActor @Sendable () async -> WalletReviewCatalog?,
        approvalCatalog: (@MainActor @Sendable () async -> WalletReviewCatalog?)? = nil,
        unlockWallets: @escaping @MainActor @Sendable (String, WalletSigningScope) async -> WalletUnlockResult,
        reloadMetadata: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        currentReviewCatalog = {
            reloadMetadata()
            return await reviewCatalog()
        }
        currentApprovalCatalog = {
            reloadMetadata()
            return await (approvalCatalog ?? reviewCatalog)()
        }
        unlock = unlockWallets
    }
}

