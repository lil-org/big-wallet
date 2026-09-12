import Foundation

enum PopupWalletReviewPolicy {
    case liveSource
    case versionedCatalog
}

@MainActor
protocol PopupWalletEnvironment: AnyObject {
    var reviewPolicy: PopupWalletReviewPolicy { get }
    func prepareForNewSession() -> WalletAccess?
    func currentReviewAccess() -> WalletAccess?
    func refreshWallets() -> Bool
    func resolveSelectedAccount(
        _ item: InternalSafariRequest.SelectedAccount,
        reviewedAccess: WalletAccess
    ) -> SpecificWalletAccount?
    func unlock(
        for session: PopupRequestSession,
        reason: String
    ) async -> WalletUnlockResult
}

@MainActor
final class SourcePopupWalletEnvironment: PopupWalletEnvironment {
    let reviewPolicy = PopupWalletReviewPolicy.liveSource

    private let startWalletsManager: () -> Bool
    private let reloadWalletsManager: () -> Bool
    private let canUseBiometrics: () -> Bool
    private let attemptBiometrics: (
        String,
        @escaping (DeviceAuthentication.Outcome) -> Void
    ) -> Void
    private var didStartWalletsManager = false

    init(
        startWalletsManager: @escaping () -> Bool = { WalletsManager.shared.start() },
        reloadWalletsManager: @escaping () -> Bool = { WalletsManager.shared.reloadFromStore() },
        canUseBiometrics: @escaping () -> Bool = { DeviceAuthentication.canUseBiometrics },
        attemptBiometrics: @escaping (
            String,
            @escaping (DeviceAuthentication.Outcome) -> Void
        ) -> Void = { DeviceAuthentication.attemptBiometrics(reason: $0, completion: $1) }
    ) {
        self.startWalletsManager = startWalletsManager
        self.reloadWalletsManager = reloadWalletsManager
        self.canUseBiometrics = canUseBiometrics
        self.attemptBiometrics = attemptBiometrics
    }

    func prepareForNewSession() -> WalletAccess? {
        if didStartWalletsManager {
            return reloadWalletsManager() ? SourceWalletAccess.shared : nil
        }
        didStartWalletsManager = true
        return startWalletsManager() ? SourceWalletAccess.shared : nil
    }

    func currentReviewAccess() -> WalletAccess? {
        SourceWalletAccess.shared
    }

    func refreshWallets() -> Bool {
        reloadWalletsManager()
    }

    func resolveSelectedAccount(
        _ item: InternalSafariRequest.SelectedAccount,
        reviewedAccess: WalletAccess
    ) -> SpecificWalletAccount? {
        guard let coin = WalletCoin.correspondingToInpageProvider(item.coin),
              let wallet = WalletsManager.shared.currentWallet(id: item.walletId),
              let account = wallet.accounts.first(where: {
                  $0.coin == coin && $0.address == item.address
              }) else { return nil }
        return SpecificWalletAccount(walletId: item.walletId, account: account)
    }

    func unlock(
        for session: PopupRequestSession,
        reason: String
    ) async -> WalletUnlockResult {
        let succeeded = await withCheckedContinuation { continuation in
            var didComplete = false
            let completeOnce: (Bool) -> Void = { succeeded in
                guard !didComplete else { return }
                didComplete = true
                continuation.resume(returning: succeeded)
            }
            guard canUseBiometrics() else {
                completeOnce(false)
                return
            }
            attemptBiometrics(reason) { outcome in
                MainActor.assumeIsolated {
                    completeOnce(outcome == .succeeded)
                }
            }
        }
        return succeeded
            ? .unlocked(RequestScopedWalletAccess(SourceWalletAccess.shared))
            : .canceled
    }
}

@MainActor
final class VaultPopupWalletEnvironment: PopupWalletEnvironment {
    let reviewPolicy = PopupWalletReviewPolicy.versionedCatalog

    private let catalogAccess: () -> WalletAccess?
    private let unlockWalletAccess: (String) async -> WalletUnlockResult

    init(
        catalogAccess: @escaping () -> WalletAccess?,
        unlockWalletAccess: @escaping (String) async -> WalletUnlockResult
    ) {
        self.catalogAccess = catalogAccess
        self.unlockWalletAccess = unlockWalletAccess
    }

    func prepareForNewSession() -> WalletAccess? {
        currentReviewAccess()
    }

    func currentReviewAccess() -> WalletAccess? {
        WalletsMetadataService.reload()
        return catalogAccess()
    }

    func refreshWallets() -> Bool {
        true
    }

    func resolveSelectedAccount(
        _ item: InternalSafariRequest.SelectedAccount,
        reviewedAccess: WalletAccess
    ) -> SpecificWalletAccount? {
        guard let coin = WalletCoin.correspondingToInpageProvider(item.coin)
        else { return nil }
        let normalized = coin.normalizedAddress(item.address)
        let matches = reviewedAccess.orderedAccounts.filter {
            $0.walletId == item.walletId &&
                $0.account.coin == coin &&
                coin.normalizedAddress($0.account.address) == normalized &&
                $0.account.derivationPath == item.derivationPath
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func unlock(
        for session: PopupRequestSession,
        reason: String
    ) async -> WalletUnlockResult {
        await unlockWalletAccess(reason)
    }
}
