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
        action: DappRequestAction,
        decision: DappApprovalDecision,
        walletAccess: WalletAccess?
    ) async -> DappExecutionResult
}
