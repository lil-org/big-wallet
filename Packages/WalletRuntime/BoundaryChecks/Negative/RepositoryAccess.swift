import WalletAuthority

@MainActor
func forbidden(wallets: WalletsManager) {
    _ = wallets.repository
}
