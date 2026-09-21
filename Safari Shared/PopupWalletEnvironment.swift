import Foundation

@MainActor
struct PopupWalletEnvironment {

    let currentReviewCatalog: () -> WalletReviewCatalog?
    let unlock: (String) async -> WalletUnlockResult

    init(
        reviewCatalog: @escaping () -> WalletReviewCatalog?,
        unlockWallets: @escaping (String) async -> WalletUnlockResult
    ) {
        currentReviewCatalog = {
            WalletsMetadataService.reload()
            return reviewCatalog()
        }
        unlock = unlockWallets
    }
}
