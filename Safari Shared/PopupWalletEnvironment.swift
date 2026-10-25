import Foundation

struct PopupWalletEnvironment: Sendable {

    let currentReviewCatalog: @MainActor @Sendable () -> WalletReviewCatalog?
    let currentApprovalCatalog: @MainActor @Sendable () -> WalletReviewCatalog?
    let unlock: @MainActor @Sendable (String, WalletSigningScope) async -> WalletUnlockResult

    nonisolated init(
        reviewCatalog: @escaping @MainActor @Sendable () -> WalletReviewCatalog?,
        approvalCatalog: (@MainActor @Sendable () -> WalletReviewCatalog?)? = nil,
        unlockWallets: @escaping @MainActor @Sendable (String, WalletSigningScope) async -> WalletUnlockResult,
        reloadMetadata: @escaping @MainActor @Sendable () -> Void = { WalletsMetadataService.reload() }
    ) {
        currentReviewCatalog = {
            reloadMetadata()
            return reviewCatalog()
        }
        currentApprovalCatalog = {
            reloadMetadata()
            return (approvalCatalog ?? reviewCatalog)()
        }
        unlock = unlockWallets
    }
}
