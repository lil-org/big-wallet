import WalletAuthority

@MainActor
func readBacking(_ review: NativeApprovalReview) {
    _ = review.approval
}
