import WalletAuthority

@MainActor
func forbidden(coordinator: NativeApprovalCoordinator) {
    coordinator.resumeAfterAuthentication()
}
