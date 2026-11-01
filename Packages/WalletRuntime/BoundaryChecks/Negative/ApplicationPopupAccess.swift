import WalletAuthority

@MainActor
func reachOtherRole(runtime: AuthorityRuntime) {
    _ = runtime.makePopupApprovalAuthority
}
