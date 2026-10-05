import Foundation

struct PopupWalletEnvironment: Sendable {

    let currentReviewCatalog: @MainActor @Sendable () -> WalletReviewCatalog?
    let currentApprovalCatalog: @MainActor @Sendable () -> WalletReviewCatalog?
    let unlock: @MainActor @Sendable (String, WalletSigningAuthorization) async -> WalletUnlockResult

    nonisolated init(
        reviewCatalog: @escaping @MainActor @Sendable () -> WalletReviewCatalog?,
        approvalCatalog: (@MainActor @Sendable () -> WalletReviewCatalog?)? = nil,
        unlockWallets: @escaping @MainActor @Sendable (String, WalletSigningAuthorization) async -> WalletUnlockResult
    ) {
        currentReviewCatalog = {
            WalletsMetadataService.reload()
            return reviewCatalog()
        }
        currentApprovalCatalog = {
            WalletsMetadataService.reload()
            return (approvalCatalog ?? reviewCatalog)()
        }
        unlock = unlockWallets
    }
}
