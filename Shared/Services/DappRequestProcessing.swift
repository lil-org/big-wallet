// ∅ 2026 lil org

@MainActor
protocol DappRequestProcessing {
    func prepare(
        _ request: SafariRequest,
        catalog: WalletReviewCatalog
    ) -> DappRequestPreparation

    func prepareWithoutWallets(
        _ request: SafariRequest
    ) -> DappRequestPreparation?

    func execute(
        request: SafariRequest,
        approval: DappApprovalValidator.Approval,
        signer: (any WalletSigning)?
    ) async -> DappExecutionResult
}
