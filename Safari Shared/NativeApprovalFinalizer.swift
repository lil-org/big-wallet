// ∅ 2026 lil org

import Foundation

enum NativeApprovalFinalizationResult: Equatable {
    case responseReady, pending, reviewRequired, interruptionRequired
}

@MainActor
final class NativeApprovalFinalizer {

    static let shared = NativeApprovalFinalizer(
        store: ExtensionBridge.shared,
        requestProcessor: DappRequestProcessor()
    )

    private let store: NativeApprovalStore
    private let refreshWalletCatalog: @MainActor () async -> WalletReviewCatalog?
    private let makeSigner: DurableApprovalExecutor.SourceSignerFactory
    private let networkResolver: (Int) -> ApprovalNetworkResolution
    private let executor: DurableApprovalExecutor

    convenience init(
        store: NativeApprovalStore,
        requestProcessor: DappRequestProcessing,
        makeSigner: DurableApprovalExecutor.SourceSignerFactory? = nil,
        networkResolver: @escaping (Int) -> ApprovalNetworkResolution = { NetworkResolver.main.approvalResolution(chainId: $0) },
        clock: @escaping @MainActor @Sendable () -> Date = { Date() },
        broadcastSender: (any ApprovedBroadcastSending)? = nil,
        broadcastTimeoutNanoseconds: UInt64 = DurableApprovalExecutor.defaultBroadcastTimeoutNanoseconds
    ) {
        self.init(
            store: store, requestProcessor: requestProcessor,
            refreshWalletCatalog: {
                guard await WalletsManager.shared.start() else { return nil }
                return WalletsManager.shared.reviewCatalog()
            },
            makeSigner: makeSigner, networkResolver: networkResolver,
            clock: clock,
            broadcastSender: broadcastSender, broadcastTimeoutNanoseconds: broadcastTimeoutNanoseconds
        )
    }

    init(
        store: NativeApprovalStore,
        requestProcessor: DappRequestProcessing,
        refreshWalletCatalog: @escaping @MainActor () async -> WalletReviewCatalog?,
        makeSigner: DurableApprovalExecutor.SourceSignerFactory? = nil,
        networkResolver: @escaping (Int) -> ApprovalNetworkResolution = {
            NetworkResolver.main.approvalResolution(chainId: $0)
        },
        clock: @escaping @MainActor @Sendable () -> Date = Date.init,
        broadcastSender: (any ApprovedBroadcastSending)? = nil,
        broadcastTimeoutNanoseconds: UInt64 =
            DurableApprovalExecutor.defaultBroadcastTimeoutNanoseconds
    ) {
        self.store = store
        self.refreshWalletCatalog = refreshWalletCatalog
        self.makeSigner = makeSigner ?? { operation in
            WalletSigningSession.fromSource(
                operation: operation,
                clock: clock
            )
        }
        self.networkResolver = networkResolver
        executor = DurableApprovalExecutor(
            store: store,
            requestProcessor: requestProcessor,
            broadcastSender: broadcastSender,
            broadcastTimeoutNanoseconds: broadcastTimeoutNanoseconds,
            clock: clock
        )
    }

    func attempt(
        snapshot: ExtensionBridge.Snapshot,
        consent: ReviewConsent
    ) async -> NativeApprovalFinalizationResult {
        switch snapshot.state {
        case .responded:
            consent.invalidateAuthorization()
            return .responseReady
        case .approving:
            return .pending
        case .queued(_, .delivered):
            return await claimAndExecute(snapshot: snapshot, consent: consent)
        case .queued:
            return .pending
        }
    }

    private func claimAndExecute(
        snapshot: ExtensionBridge.Snapshot,
        consent: ReviewConsent
    ) async -> NativeApprovalFinalizationResult {
        guard let receipt = consent.nativeReceipt,
              snapshot.nativeDeliveryReceipt == receipt,
              snapshot.requestBinding == consent.binding else {
            return .interruptionRequired
        }
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
