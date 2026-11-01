import WalletAuthority

@MainActor
func reachOtherRole(runtime: PopupAuthorityRuntime) {
    _ = runtime.reconcileVault
}
