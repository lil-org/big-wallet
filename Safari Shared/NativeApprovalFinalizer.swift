// ∅ 2026 lil org

import Foundation

enum NativeApprovalFinalizationResult: Equatable {
    case responseReady, pending, reviewRequired, interruptionRequired
}

@MainActor
final class NativeApprovalFinalizer {

    static let shared = NativeApprovalFinalizer(store: ExtensionBridge.shared)

    private let store: NativeApprovalStore
    private let refreshWalletCatalog: @MainActor () async -> WalletReviewCatalog?
    private let makeSigner: DurableApprovalExecutor.SourceSignerFactory
    private let networkResolver: (Int) -> ApprovalNetworkResolution
    private let executor: DurableApprovalExecutor

    init(
        store: NativeApprovalStore,
        executionEnvironment: DurableApprovalExecutor.Environment = .live,
        refreshWalletCatalog: @escaping @MainActor () async -> WalletReviewCatalog? = {
            guard await WalletsManager.shared.start() else { return nil }
            return WalletsManager.shared.reviewCatalog()
        },
        makeSigner: DurableApprovalExecutor.SourceSignerFactory? = nil,
        networkResolver: @escaping (Int) -> ApprovalNetworkResolution = {
            NetworkResolver.main.approvalResolution(chainId: $0)
        }
    ) {
        self.store = store
        self.refreshWalletCatalog = refreshWalletCatalog
        let clock = executionEnvironment.clock
        self.makeSigner = makeSigner ?? { authorization in
            WalletSigningSession.fromSource(
                authorization: authorization,
                clock: clock
            )
        }
        self.networkResolver = networkResolver
        executor = DurableApprovalExecutor(
            store: store,
            environment: executionEnvironment
        )
    }

    func attempt(consent: ReviewConsent) async -> NativeApprovalFinalizationResult {
        let claim: ExtensionBridge.ApprovalClaim
        switch await store.claimNativeExecution(consent: consent) {
        case .claimed(let value):
            claim = value
        case .executing:
            return .pending
        case .reviewRequired:
            return .reviewRequired
        case .responded, .missing:
            consent.invalidateAuthorization()
            return .responseReady
        case .ownershipLost, .unavailable:
            consent.invalidateAuthorization()
            return .interruptionRequired
        }
        let result = await executor.execute(claim: claim, prepare: { _ in
            .ready(consent: consent, signing: .source(self.makeSigner))
        }, resolve: resolve)
        switch result {
        case .persisted:
            return .responseReady
        case .reviewRequired:
            return .reviewRequired
        case .ownershipLost, .retryablePersistenceFailure, .abandoned:
            return .interruptionRequired
        }
    }

    private func resolve(_ consent: ReviewConsent) async -> DurableApprovalExecutor.Resolution {
        await DappApprovalResolver.resolve(
            consent,
            refreshWalletCatalog: refreshWalletCatalog,
            networkResolver: networkResolver
        )
    }
}
