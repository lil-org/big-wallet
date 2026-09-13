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

struct ProductionDappRequestProcessor: DappRequestProcessing {
    func prepare(
        _ request: SafariRequest,
        walletAccess: WalletAccess
    ) -> DappRequestPreparation {
        DappRequestProcessor.prepare(request, walletAccess: walletAccess)
    }

    func prepareWithoutWallets(
        _ request: SafariRequest
    ) -> DappRequestPreparation? {
        DappRequestProcessor.prepareWithoutWallets(request)
    }

    func execute(
        request: SafariRequest,
        action: DappRequestAction,
        decision: DappApprovalDecision,
        walletAccess: WalletAccess?
    ) async -> DappExecutionResult {
        await DappRequestProcessor.execute(
            request: request,
            action: action,
            decision: decision,
            walletAccess: walletAccess
        )
    }
}
