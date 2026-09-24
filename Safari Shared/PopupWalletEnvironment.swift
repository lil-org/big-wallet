import Foundation

@MainActor
struct PopupWalletEnvironment {

    let currentReviewCatalog: () -> WalletReviewCatalog?
    let unlock: (String, WalletSigningAuthorization) async -> WalletUnlockResult

    init(
        reviewCatalog: @escaping () -> WalletReviewCatalog?,
        unlockWallets: @escaping (String, WalletSigningAuthorization) async -> WalletUnlockResult
    ) {
        currentReviewCatalog = {
            WalletsMetadataService.reload()
            return reviewCatalog()
        }
        unlock = unlockWallets
    }
}
