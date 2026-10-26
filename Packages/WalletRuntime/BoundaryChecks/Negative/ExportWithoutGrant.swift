import WalletDomain
import WalletAuthority

@MainActor
func forbidden(wallets: WalletsManager, wallet: WalletSnapshot) async throws {
    _ = try await wallets.exportMnemonic(wallet: wallet)
}
