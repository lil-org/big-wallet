// ∅ 2026 lil org

import Foundation

enum NativeApprovalFinalizationResult: Equatable {
    case responseReady, pending, reviewRequired, interruptionRequired
}

@MainActor
final class NativeApprovalFinalizer {
    typealias SigningPreparationFactory = @MainActor @Sendable (WalletSigningScope) -> WalletSigningPreparation

    static let shared = NativeApprovalFinalizer(store: ExtensionBridge.shared)

    private let store: NativeApprovalStore
    private let refreshWalletCatalog: @MainActor () async -> WalletReviewCatalog?
    private let makeSigningPreparation: SigningPreparationFactory
    private let networkResolver: (Int) -> ApprovalNetworkResolution
    private let customDefinitionResult: @MainActor @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult
    private let executor: DurableApprovalExecutor

    init(
        store: NativeApprovalStore,
        executionEnvironment: DurableApprovalExecutor.Environment = .live,
        refreshWalletCatalog: @escaping @MainActor () async -> WalletReviewCatalog? = {
            guard await WalletsManager.shared.start() else { return nil }
            return WalletsManager.shared.reviewCatalog()
        },
        makeSigningPreparation: SigningPreparationFactory? = nil,
        networkResolver: @escaping (Int) -> ApprovalNetworkResolution = {
            NetworkResolver.main.approvalResolution(chainId: $0)
        },
        customDefinitionResult: @escaping @MainActor @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult = {
            Networks.existingCustomDefinitionResult(networkFromDapp: $0)
        }
    ) {
        self.store = store
        self.refreshWalletCatalog = refreshWalletCatalog
        let clock = executionEnvironment.clock
        self.makeSigningPreparation = makeSigningPreparation ?? { scope in
            WalletSigningPreparation.fromSource(
                scope: scope,
                clock: clock
            )
        }
        self.networkResolver = networkResolver
        self.customDefinitionResult = customDefinitionResult
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
        defer { consent.invalidateAuthorization() }
        let outcome = await executor.execute(
            claim: claim,
            prepare: { _ -> DurableApprovalExecutor.Preparation<Never> in
                let preparation = consent.intent.action.signingAccount.map { account in
                    self.makeSigningPreparation(WalletSigningScope(
                        handle: claim.handle, approvedAccount: account,
                        signingDeadline: claim.authority.signingDeadline(for: claim.request)
                    ))
                }
                return .ready(consent: consent, signing: preparation)
            },
            resolve: resolve
        )
        switch outcome {
        case .finished(.persisted):
            return .responseReady
        case .finished(.reviewRequired):
            return .reviewRequired
        case .finished(.ownershipLost), .finished(.retryablePersistenceFailure), .finished(.abandoned):
            return .interruptionRequired
        case .preparationStopped(let reason, _):
            switch reason {}
        }
    }

    private func resolve(_ consent: ReviewConsent) async -> DurableApprovalExecutor.Resolution {
        await DappApprovalResolver.resolve(
            consent,
            refreshWalletCatalog: refreshWalletCatalog,
            networkResolver: networkResolver,
            customDefinitionResult: customDefinitionResult
        )
    }
}
