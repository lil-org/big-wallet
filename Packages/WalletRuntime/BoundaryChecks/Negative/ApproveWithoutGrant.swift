import WalletAuthority

@MainActor
func forbidden(coordinator: NativeApprovalCoordinator, review: NativeApprovalReview) {
    coordinator.approveMessage(solanaCluster: nil, review: review)
}
