// ∅ 2026 lil org

@MainActor
protocol DappRequestProcessing {
    func prepare(
        _ request: SafariRequest,
        walletAccess: WalletAccess
    ) -> DappRequestPreparation

    func prepareWithoutWallets(
        _ request: SafariRequest
    ) -> DappRequestPreparation?

    func execute(
        request: SafariRequest,
        approval: DappApprovalValidator.Approval,
        walletAccess: WalletAccess?
    ) async -> DappExecutionResult
}
