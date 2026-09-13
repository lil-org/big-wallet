import Foundation

@MainActor
protocol PopupWalletEnvironment: AnyObject {
    func currentReviewAccess() -> WalletAccess?
    func unlock(
        for session: PopupRequestSession,
        reason: String
    ) async -> WalletUnlockResult
}

@MainActor
final class VaultPopupWalletEnvironment: PopupWalletEnvironment {

    private let catalogAccess: () -> WalletAccess?
    private let unlockWalletAccess: (String) async -> WalletUnlockResult

    init(
        catalogAccess: @escaping () -> WalletAccess?,
        unlockWalletAccess: @escaping (String) async -> WalletUnlockResult
    ) {
        self.catalogAccess = catalogAccess
        self.unlockWalletAccess = unlockWalletAccess
    }

    func currentReviewAccess() -> WalletAccess? {
        WalletsMetadataService.reload()
        return catalogAccess()
    }

    func unlock(
        for session: PopupRequestSession,
        reason: String
    ) async -> WalletUnlockResult {
        await unlockWalletAccess(reason)
    }
}
