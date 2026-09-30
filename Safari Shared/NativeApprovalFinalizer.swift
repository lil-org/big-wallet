// ∅ 2026 lil org

import Foundation

enum NativeApprovalFinalizationResult: Equatable {
    case responseReady, pending, interruptionRequired
}

@MainActor
final class NativeApprovalFinalizer {

    nonisolated static let maximumTransactionDecisionAge = ExtensionBridge.maximumTransactionDecisionAge

    static let shared = NativeApprovalFinalizer(
        store: ExtensionBridge.shared,
        requestProcessor: DappRequestProcessor()
    )

    private let store: NativeApprovalStore
    private let requestProcessor: DappRequestProcessing
    private let refreshWalletCatalog: () -> WalletReviewCatalog?
    private let makeSigner: (
        ApprovedWalletSigningOperation,
        @escaping @MainActor (ExtensionBridge.Handle) async -> Bool
    ) -> any WalletSigning
    private let networkResolver: (String) -> EthereumNetwork?
    private let clock: () -> Date
    private let executor: DurableApprovalExecutor

    init(
        store: NativeApprovalStore,
        requestProcessor: DappRequestProcessing,
        refreshWalletCatalog: @escaping () -> WalletReviewCatalog? = {
            guard WalletsManager.shared.start() else { return nil }
            return WalletsManager.shared.reviewCatalog()
        },
        makeSigner: ((
            ApprovedWalletSigningOperation,
            @escaping @MainActor (ExtensionBridge.Handle) async -> Bool
        ) -> any WalletSigning)? = nil,
        networkResolver: @escaping (String) -> EthereumNetwork? = {
            Networks.withChainIdHex($0)
        },
        clock: @escaping () -> Date = Date.init,
        broadcastSender: (any ApprovedBroadcastSending)? = nil,
        broadcastTimeoutNanoseconds: UInt64 =
            DurableApprovalExecutor.defaultBroadcastTimeoutNanoseconds
    ) {
        self.store = store
        self.requestProcessor = requestProcessor
        self.refreshWalletCatalog = refreshWalletCatalog
        self.makeSigner = makeSigner ?? { operation, authorityIsCurrent in
            WalletSigningSession.fromSource(
                operation: operation,
                authorityIsCurrent: authorityIsCurrent,
                clock: clock
            )
        }
        self.networkResolver = networkResolver
        self.clock = clock
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
              snapshot.requestBinding == consent.review.binding else {
            return .interruptionRequired
        }
        let claim: ExtensionBridge.ApprovalClaim
        switch await store.claimNativeExecution(
            handle: snapshot.handle,
            nativeDeliveryNonce: receipt.nativeDeliveryNonce,
            runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier,
            approvedAt: consent.approvedAt
        ) {
        case .claimed(let value):
            claim = value
        case .executing:
            return .pending
        case .responded, .missing:
            return .responseReady
        case .ownershipLost, .unavailable:
            return .interruptionRequired
        }
        defer { claim.releaseIfUnconsumed() }
        let reservation: ExtensionBridge.ExecutionReservation
        switch await store.begin(claim: claim) {
        case .began(let value):
            reservation = value
        case .ownershipLost:
            return .interruptionRequired
        case .retryablePersistenceFailure:
            _ = await store.release(claim: claim)
            return .interruptionRequired
        }
        defer { reservation.releaseLease() }
        return await prepareAndExecute(reservation: reservation, consent: consent)
    }

    private func prepareAndExecute(
        reservation: ExtensionBridge.ExecutionReservation,
        consent: ReviewConsent
    ) async -> NativeApprovalFinalizationResult {
        guard case .native(let approvedAt, let executionContext) = reservation.authority,
              !Task.isCancelled else {
            return await rollback(reservation)
        }
        let request = reservation.request
        let now = clock()
        let age = now.timeIntervalSince(executionContext.observedAt)
        guard age >= 0,
              now < executionContext.executionDeadline else {
            return await rollback(reservation)
        }
        guard transactionDecisionIsFresh(approvedAt: approvedAt, request: request) else {
            return await complete(reservation, resolution: Self.staleResolution)
        }

        let preparation: DappRequestPreparation
        let preparationCatalog: WalletReviewCatalog?
        if let walletIndependent = requestProcessor.prepareWithoutWallets(request) {
            preparation = walletIndependent
            preparationCatalog = nil
        } else {
            guard let refreshedAccess = refreshWalletCatalog() else {
                return await rollback(reservation)
            }
            preparationCatalog = refreshedAccess
            CustomNetworkCache.shared.invalidate()
            preparation = requestProcessor.prepare(request, catalog: refreshedAccess)
        }
        switch preparation {
        case .immediate(let resolution):
            return await complete(reservation, resolution: resolution)
        case .approval(let action):
            guard transactionDecisionIsFresh(approvedAt: approvedAt, request: request) else {
                return await complete(reservation, resolution: Self.staleResolution)
            }
            let accounts: [SpecificWalletAccount]?
            if case .accountSelection = consent.decision {
                accounts = preparationCatalog?.orderedAccounts
            } else {
                accounts = nil
            }
            switch consent.resolve(
                currentAction: action,
                accounts: accounts,
                networkResolver: networkResolver
            ) {
            case .success(let approval):
                if let approvedAccount = approval.approval.signingAccount {
                    guard preparationCatalog?.orderedAccounts.contains(where: {
                        approvedAccount.matches(walletID: $0.walletId, account: $0.account)
                    }) == true else {
                        return await complete(reservation, resolution: Self.staleResolution)
                    }
                }
                let result = await executor.executeNative(
                    reservation: reservation,
                    approval: approval
                ) { permit in
                    guard approval.approval.signingAccount != nil,
                          let operation = ApprovedWalletSigningOperation(permit: permit) else {
                        return nil
                    }
                    return self.makeSigner(operation) {
                        await self.store.authorityIsCurrent(handle: $0)
                    }
                }
                switch result {
                case .persisted:
                    return .responseReady
                case .ownershipLost, .retryablePersistenceFailure, .released:
                    return .interruptionRequired
                }
            case .failure(.staleTransaction), .failure(.staleAccount):
                return await complete(reservation, resolution: Self.staleResolution)
            case .failure(.invalidDecision):
                return await complete(reservation, resolution: .failure(.internalError))
            }
        }
    }

    private func complete(
        _ reservation: ExtensionBridge.ExecutionReservation,
        resolution: ImmediateResolution
    ) async -> NativeApprovalFinalizationResult {
        guard !Task.isCancelled, clock() < reservation.executionDeadline else {
            return await rollback(reservation)
        }
        switch await store.complete(reservation: reservation, resolution: resolution) {
        case .persisted:
            return .responseReady
        case .ownershipLost, .retryablePersistenceFailure:
            return .interruptionRequired
        }
    }

    private func rollback(
        _ reservation: ExtensionBridge.ExecutionReservation
    ) async -> NativeApprovalFinalizationResult {
        _ = await store.rollback(reservation: reservation)
        return .interruptionRequired
    }

    private func transactionDecisionIsFresh(
        approvedAt: Date,
        request: SafariRequest
    ) -> Bool {
        guard requestRequiresFreshTransactionDecision(request) else { return true }
        let age = clock().timeIntervalSince(approvedAt)
        return age >= 0 && age <= Self.maximumTransactionDecisionAge
    }

    private func requestRequiresFreshTransactionDecision(
        _ request: SafariRequest
    ) -> Bool {
        switch request.body {
        case .ethereum(let body):
            switch body.method {
            case .signTransaction:
                return true
            case .addEthereumChain, .ecRecover, .requestAccounts,
                 .signMessage, .signPersonalMessage, .signTypedMessage,
                 .switchEthereumChain:
                return false
            }
        case .solana(let body):
            switch body.method {
            case .signTransaction, .signAllTransactions, .signAndSendTransaction:
                return true
            case .connect, .signMessage:
                return false
            }
        case .unknown:
            return false
        }
    }

    private static var staleResolution: ImmediateResolution {
        .failure(ProviderResponseError(
            message: Strings.providerNotReady,
            code: 4100
        ))
    }
}
