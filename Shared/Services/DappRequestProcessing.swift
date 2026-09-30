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
        permit: ExtensionBridge.ApprovedExecutionPermit,
        signer: (any WalletSigning)?
    ) async -> ApprovedExecutionResult
}
