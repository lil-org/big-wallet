import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

@MainActor
protocol DappRequestProcessing {
    func prepare(
        _ binding: ExtensionBridge.RequestBinding,
        catalog: WalletReviewCatalog?
    ) -> DappRequestPreparation

    func execute(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        signer: (any WalletSigning)?
    ) async -> ApprovedExecutionResult
}

enum DappRequestPreparationResult: Sendable {
    case catalogUnavailable
    case prepared(DappRequestPreparation, catalog: WalletReviewCatalog?)
}

extension DappRequestProcessing {
    func prepare(
        _ binding: ExtensionBridge.RequestBinding,
        loadingCatalog: () -> WalletReviewCatalog?
    ) -> DappRequestPreparationResult {
        let initial = prepare(binding, catalog: nil)
        guard case .needsCatalog = initial else {
            return .prepared(initial, catalog: nil)
        }
        guard let catalog = loadingCatalog() else { return .catalogUnavailable }
        if let account = binding.request.authorizedAccount,
           catalog.availability(of: account) == .unavailable {
            return .catalogUnavailable
        }
        return .prepared(prepare(binding, catalog: catalog), catalog: catalog)
    }
}

