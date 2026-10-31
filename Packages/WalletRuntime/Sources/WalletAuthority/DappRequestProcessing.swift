import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

@MainActor
protocol DappRequestProcessing {
    func prepare(
        _ binding: ExtensionBridge.RequestBinding,
        catalog: WalletReviewCatalog?
    ) async -> DappRequestPreparation

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
        loadingCatalog: () async -> WalletReviewCatalog?
    ) async -> DappRequestPreparationResult {
        let initial = await prepare(binding, catalog: nil)
        guard !Task.isCancelled else { return .prepared(.unavailable, catalog: nil) }
        guard case .needsCatalog(let resolve) = initial else {
            return .prepared(initial, catalog: nil)
        }
        let loadedCatalog = await loadingCatalog()
        guard !Task.isCancelled else { return .prepared(.unavailable, catalog: nil) }
        guard let catalog = loadedCatalog else { return .catalogUnavailable }
        if let account = binding.request.authorizedAccount,
           catalog.availability(of: account) == .unavailable {
            return .catalogUnavailable
        }
        guard !Task.isCancelled else { return .prepared(.unavailable, catalog: nil) }
        return .prepared(resolve(catalog), catalog: catalog)
    }
}

