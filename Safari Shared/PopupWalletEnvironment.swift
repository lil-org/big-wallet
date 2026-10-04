import Foundation

struct PopupWalletEnvironment: Sendable {

    let currentReviewCatalog: @MainActor @Sendable () -> WalletReviewCatalog?
    let unlock: @MainActor @Sendable (String, WalletSigningAuthorization) async -> WalletUnlockResult

    nonisolated init(
        reviewCatalog: @escaping @MainActor @Sendable () -> WalletReviewCatalog?,
        unlockWallets: @escaping @MainActor @Sendable (String, WalletSigningAuthorization) async -> WalletUnlockResult
    ) {
        currentReviewCatalog = {
            WalletsMetadataService.reload()
            return reviewCatalog()
        }
        unlock = unlockWallets
    }
}
