import WalletAuthority

@MainActor
func forbidden(_ runtime: AuthorityRuntime) {
    _ = runtime.wallets
}
