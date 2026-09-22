import Foundation

@MainActor
struct PopupWalletEnvironment {

    let currentReviewCatalog: () -> WalletReviewCatalog?
    let unlock: (String, WalletAccountDescriptor) async -> WalletUnlockResult

    init(
        reviewCatalog: @escaping () -> WalletReviewCatalog?,
        unlockWallets: @escaping (String, WalletAccountDescriptor) async -> WalletUnlockResult
    ) {
        currentReviewCatalog = {
            WalletsMetadataService.reload()
            return reviewCatalog()
        }
        unlock = unlockWallets
    }
}
