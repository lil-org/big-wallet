// ∅ 2026 lil org

@MainActor
protocol DappRequestProcessing {
    func prepare(
        _ binding: ExtensionBridge.RequestBinding,
        catalog: WalletReviewCatalog
    ) -> DappRequestPreparation

    func prepareWithoutWallets(
        _ binding: ExtensionBridge.RequestBinding
    ) -> DappRequestPreparation?

    func execute(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        signer: (any WalletSigning)?
    ) async -> ApprovedExecutionResult
}
