// ∅ 2026 lil org

import Foundation

enum NativeApprovalFinalizationResult: Equatable {
    case responseReady, interrupted, pending, unavailable
}

@MainActor
final class NativeApprovalFinalizer {

    nonisolated static let maximumTransactionDecisionAge: TimeInterval = 30

    static let shared = NativeApprovalFinalizer(
        store: ExtensionBridge.shared,
        requestProcessor: DappRequestProcessor()
    )

    private let store: NativeApprovalStore
    private let requestProcessor: DappRequestProcessing
    private let refreshWalletAccess: () -> WalletAccess?
    private let networkResolver: (String) -> EthereumNetwork?
    private let clock: () -> Date
    private let executor: DurableApprovalExecutor

    init(
        store: NativeApprovalStore,
        requestProcessor: DappRequestProcessing,
        refreshWalletAccess: @escaping () -> WalletAccess? = {
            guard WalletsManager.shared.start() else { return nil }
            return SourceWalletAccess.shared
        },
        networkResolver: @escaping (String) -> EthereumNetwork? = {
            Networks.withChainIdHex($0)
        },
        clock: @escaping () -> Date = Date.init,
        broadcastTimeoutNanoseconds: UInt64 =
            DurableApprovalExecutor.defaultBroadcastTimeoutNanoseconds
    ) {
        self.store = store
        self.requestProcessor = requestProcessor
        self.refreshWalletAccess = refreshWalletAccess
        self.networkResolver = networkResolver
        self.clock = clock
        executor = DurableApprovalExecutor(
            store: store,
            broadcastTimeoutNanoseconds: broadcastTimeoutNanoseconds,
            clock: clock
        )
    }

    func finalize(
        handle: ExtensionBridge.Handle,
        authorization: ExtensionBridge.NativeApprovalAuthorization
    ) async -> NativeApprovalFinalizationResult {
        let snapshot: ExtensionBridge.Snapshot
        switch await store.load(handle: handle) {
        case .found(let value):
            snapshot = value
        case .missing:
            return .responseReady
        case .unavailable:
            return .unavailable
        }
        switch snapshot.state {
        case .responded:
            return .responseReady
        case .approving:
            return .pending
        case .queued(let request, .staged):
            return await claimAndFinalize(
                snapshot: snapshot,
                request: request,
                authorization: authorization
            )
        case .queued:
            return .pending
        }
    }

    private func claimAndFinalize(
        snapshot: ExtensionBridge.Snapshot,
        request: SafariRequest,
        authorization: ExtensionBridge.NativeApprovalAuthorization
    ) async -> NativeApprovalFinalizationResult {
        guard snapshot.nativeDeliveryReceipt == authorization.receipt,
              snapshot.nativeApproval?.approvedAt == authorization.approvedAt else {
            return .unavailable
        }
        let nativeClaim: ExtensionBridge.NativeExecutionClaim
        let claimResult = await store.claimNativeExecution(
            handle: snapshot.handle,
            nativeDeliveryNonce: authorization.receipt.nativeDeliveryNonce,
            runtimeInstanceIdentifier: authorization.receipt.owner.runtimeInstanceIdentifier,
            approvedAt: authorization.approvedAt
        )
        switch claimResult {
        case .claimed(let value):
            nativeClaim = value
        case .notStaged, .executing:
            return .pending
        case .responded, .missing:
            return .responseReady
        case .unavailable:
            return .unavailable
        }

        defer { nativeClaim.approvalClaim.releaseLease() }
        let executionContext = nativeClaim.executionContext
        let now = clock()
        let age = now.timeIntervalSince(executionContext.observedAt)
        guard age >= 0,
              now < executionContext.executionDeadline else {
            return await interrupt(handle: snapshot.handle, authorization: authorization)
        }

        guard transactionDecisionIsFresh(nativeClaim, request: request) else {
            return await completeStaleTransactionDecision(
                nativeClaim,
                request: request,
                authorization: authorization,
                executionContext: executionContext
            )
        }

        guard DurableApprovalExecutor.approvalRevisionsMatch(
            request: request,
            stored: snapshot.revisions,
            current: executionContext.revisions
        ) else {
            return await execute(
                claim: nativeClaim.approvalClaim,
                markingApprovalCommitted: false,
                authorization: authorization,
                executionContext: executionContext
            ) {
                .response(Self.staleResponse(for: request))
            }
        }

        let preparation: DappRequestPreparation
        let walletAccess: WalletAccess?
        if let walletIndependent = requestProcessor.prepareWithoutWallets(request) {
            preparation = walletIndependent
            walletAccess = nil
        } else {
            guard let refreshedAccess = refreshWalletAccess() else {
                return await interrupt(handle: snapshot.handle, authorization: authorization)
            }
            CustomNetworkCache.shared.invalidate()
            walletAccess = refreshedAccess
            preparation = requestProcessor.prepare(
                request,
                walletAccess: refreshedAccess
            )
        }
        switch preparation {
        case .response(let response):
            return await execute(
                claim: nativeClaim.approvalClaim,
                markingApprovalCommitted: false,
                authorization: authorization,
                executionContext: executionContext
            ) { .response(response) }
        case .approval(let action):
            let accounts: [SpecificWalletAccount]?
            if case .accountSelection = authorization.decision {
                accounts = walletAccess?.orderedAccounts
            } else {
                accounts = nil
            }
            switch DappApprovalValidator.resolve(
                action: action,
                decision: authorization.decision,
                accounts: accounts,
                networkResolver: networkResolver
            ) {
            case .success:
                break
            case .failure(.staleTransaction):
                return await completeStaleTransactionDecision(
                    nativeClaim,
                    request: request,
                    authorization: authorization,
                    executionContext: executionContext
                )
            case .failure(.invalidDecision):
                return await persistInternalError(
                    claim: nativeClaim.approvalClaim,
                    request: request,
                    authorization: authorization,
                    executionContext: executionContext
                )
            }
            return await execute(
                claim: nativeClaim.approvalClaim,
                preExecutionValidation: {
                    self.transactionDecisionIsFresh(
                        nativeClaim,
                        request: request
                    )
                        ? nil
                        : Self.staleResponse(for: request)
                },
                authorization: authorization,
                executionContext: executionContext
            ) {
                await self.requestProcessor.execute(
                    request: request,
                    action: action,
                    decision: authorization.decision,
                    walletAccess: walletAccess
                )
            }
        }
    }

    private func transactionDecisionIsFresh(
        _ nativeClaim: ExtensionBridge.NativeExecutionClaim,
        request: SafariRequest
    ) -> Bool {
        guard requestRequiresFreshTransactionDecision(request) else {
            return true
        }
        let age = clock().timeIntervalSince(nativeClaim.approvedAt)
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
            case .signTransaction, .signAllTransactions,
                 .signAndSendTransaction:
                return true
            case .connect, .signMessage:
                return false
            }
        case .unknown:
            return false
        }
    }

    private func completeStaleTransactionDecision(
        _ nativeClaim: ExtensionBridge.NativeExecutionClaim,
        request: SafariRequest,
        authorization: ExtensionBridge.NativeApprovalAuthorization,
        executionContext: ExtensionBridge.NativeExecutionContext
    ) async -> NativeApprovalFinalizationResult {
        await execute(
            claim: nativeClaim.approvalClaim,
            markingApprovalCommitted: false,
            authorization: authorization,
            executionContext: executionContext
        ) {
            .response(Self.staleResponse(for: request))
        }
    }

    private func persistInternalError(
        claim: ExtensionBridge.ApprovalClaim,
        request: SafariRequest,
        authorization: ExtensionBridge.NativeApprovalAuthorization,
        executionContext: ExtensionBridge.NativeExecutionContext
    ) async -> NativeApprovalFinalizationResult {
        return await execute(
            claim: claim,
            markingApprovalCommitted: false,
            authorization: authorization,
            executionContext: executionContext
        ) {
            .response(ResponseToExtension(
                for: request,
                payload: .error(.internalError)
            ))
        }
    }

    private func interrupt(
        handle: ExtensionBridge.Handle,
        authorization: ExtensionBridge.NativeApprovalAuthorization
    ) async -> NativeApprovalFinalizationResult {
        switch await store.interruptNativeApproval(
            handle: handle,
            nativeDeliveryNonce: authorization.receipt.nativeDeliveryNonce,
            runtimeInstanceIdentifier: authorization.receipt.owner.runtimeInstanceIdentifier
        ) {
        case .interrupted: return .interrupted
        case .responseReady: return .responseReady
        case .ownershipLost: return await reconcileOwnershipLoss(handle: handle)
        case .retryablePersistenceFailure: return .unavailable
        }
    }

    private func execute(
        claim: ExtensionBridge.ApprovalClaim,
        markingApprovalCommitted: Bool = true,
        preExecutionValidation: (() -> ResponseToExtension?)? = nil,
        authorization: ExtensionBridge.NativeApprovalAuthorization,
        executionContext: ExtensionBridge.NativeExecutionContext,
        operation: @escaping () async -> DappExecutionResult
    ) async -> NativeApprovalFinalizationResult {
        let result = await executor.executeNative(
            claim: claim,
            context: executionContext,
            markingApprovalCommitted: markingApprovalCommitted,
            preExecutionValidation: preExecutionValidation,
            operation: operation
        )
        switch result {
        case .persisted:
            return .responseReady
        case .ownershipLost, .beginRetryablePersistenceFailure,
             .retryablePersistenceFailure, .rolledBack:
            return await interrupt(handle: claim.handle, authorization: authorization)
        }
    }

    private func reconcileOwnershipLoss(
        handle: ExtensionBridge.Handle
    ) async -> NativeApprovalFinalizationResult {
        switch await store.load(handle: handle) {
        case .found(let snapshot):
            return snapshot.phase == .responded ? .responseReady : .pending
        case .missing:
            return .responseReady
        case .unavailable:
            return .unavailable
        }
    }

    private static func staleResponse(
        for request: SafariRequest
    ) -> ResponseToExtension {
        ResponseToExtension(
            for: request,
            payload: .error(ProviderResponseError(
                message: Strings.providerNotReady,
                code: 4100
            ))
        )
    }
}
