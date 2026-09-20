import Foundation

@MainActor
struct PopupWalletEnvironment {

    let currentReviewAccess: () -> WalletAccess?
    let unlock: (String) async -> WalletUnlockResult

    init(
        catalogAccess: @escaping () -> WalletAccess?,
        unlockWalletAccess: @escaping (String) async -> WalletUnlockResult
    ) {
        currentReviewAccess = {
            WalletsMetadataService.reload()
            return catalogAccess()
        }
        unlock = unlockWalletAccess
    }
}
