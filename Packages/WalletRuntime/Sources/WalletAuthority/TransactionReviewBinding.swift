import WalletDomain

enum TransactionReviewBinding {
    static func preservesPayload(_ candidate: Transaction, reviewed: Transaction) -> Bool {
        candidate.from == reviewed.from &&
            candidate.to == reviewed.to && candidate.value == reviewed.value &&
            candidate.data == reviewed.data && candidate.accessList == reviewed.accessList &&
            candidate.feeIntent == reviewed.feeIntent
    }
}
