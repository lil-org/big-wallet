// ∅ 2026 lil org

import Foundation

enum NativeApprovalFinalizationResult: Equatable {
    case responseReady, pending, interruptionRequired
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
            broadcastTimeoutNanoseconds: broadcastTimeoutNanoseconds,
            clock: clock
        )
    }

    func attempt(
        snapshot: ExtensionBridge.Snapshot,
        authorization: ExtensionBridge.NativeApprovalAuthorization
    ) async -> NativeApprovalFinalizationResult {
        switch snapshot.state {
        case .responded:
            return .responseReady
        case .approving:
            return .pending
        case .queued(let request, .delivered):
            return await claimAndExecute(
                snapshot: snapshot,
                request: request,
                authorization: authorization
            )
        case .queued:
            return .pending
        }
    }

    private func claimAndExecute(
        snapshot: ExtensionBridge.Snapshot,
        request: SafariRequest,
        authorization: ExtensionBridge.NativeApprovalAuthorization
    ) async -> NativeApprovalFinalizationResult {
        guard snapshot.nativeDeliveryReceipt == authorization.receipt else {
            return .interruptionRequired
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
        case .executing:
            return .pending
        case .responded, .missing:
            return .responseReady
        case .ownershipLost, .unavailable:
            return .interruptionRequired
        }

        let result = await executor.executeNative(
            claim: nativeClaim.approvalClaim,
            context: nativeClaim.executionContext
        ) {
            await self.prepareAndExecute(
                nativeClaim: nativeClaim,
                request: request,
                authorization: authorization
            )
        }
        switch result {
        case .persisted:
            return .responseReady
        case .ownershipLost, .retryablePersistenceFailure, .released:
            return .interruptionRequired
        }
    }

    private func prepareAndExecute(
        nativeClaim: ExtensionBridge.NativeExecutionClaim,
        request: SafariRequest,
        authorization: ExtensionBridge.NativeApprovalAuthorization
    ) async -> DappExecutionResult {
        let executionContext = nativeClaim.executionContext
        let now = clock()
        let age = now.timeIntervalSince(executionContext.observedAt)
        guard age >= 0,
              now < executionContext.executionDeadline else { return .rollback }
        guard transactionDecisionIsFresh(nativeClaim, request: request) else {
            return .response(Self.staleResponse(for: request), approvalCommitted: false)
        }

        let preparation: DappRequestPreparation
        let signingCatalog: WalletReviewCatalog?
        if let walletIndependent = requestProcessor.prepareWithoutWallets(request) {
            preparation = walletIndependent
            signingCatalog = nil
        } else {
            guard let refreshedAccess = refreshWalletCatalog() else { return .rollback }
            signingCatalog = refreshedAccess
            CustomNetworkCache.shared.invalidate()
            preparation = requestProcessor.prepare(request, catalog: refreshedAccess)
        }
        switch preparation {
        case .response(let response):
            return .response(response, approvalCommitted: false)
        case .approval(let action):
            guard transactionDecisionIsFresh(nativeClaim, request: request) else {
                return .response(Self.staleResponse(for: request), approvalCommitted: false)
            }
            let accounts: [SpecificWalletAccount]?
            if case .accountSelection = authorization.decision {
                accounts = refreshWalletCatalog()?.orderedAccounts
            } else {
                accounts = nil
            }
            switch DappApprovalValidator.resolve(
                action: action,
                decision: authorization.decision,
                accounts: accounts,
                networkResolver: networkResolver
            ) {
            case .success(let approval):
                let executionSigner: (any WalletSigning)?
                if let approvedAccount = approval.signingAccount {
                    guard signingCatalog?.orderedAccounts.contains(where: {
                        approvedAccount.matches(walletID: $0.walletId, account: $0.account)
                    }) == true else {
                        return .response(Self.staleResponse(for: request), approvalCommitted: false)
                    }
                    let deadline = requestRequiresFreshTransactionDecision(request)
                        ? min(executionContext.executionDeadline,
                              nativeClaim.approvedAt.addingTimeInterval(Self.maximumTransactionDecisionAge))
                        : executionContext.executionDeadline
                    guard let operation = ApprovedWalletSigningOperation(
                        request: request, approval: approval,
                        authorization: WalletSigningAuthorization(
                            handle: nativeClaim.approvalClaim.handle,
                            approvedAccount: approvedAccount,
                            signingDeadline: deadline
                        )
                    ) else { return .rollback }
                    executionSigner = makeSigner(operation) {
                        await self.store.authorityIsCurrent(handle: $0)
                    }
                } else {
                    executionSigner = nil
                }
                defer { executionSigner?.invalidate() }
                return await requestProcessor.execute(
                    request: request,
                    approval: approval,
                    signer: executionSigner
                )
            case .failure(.staleTransaction), .failure(.staleAccount):
                return .response(Self.staleResponse(for: request), approvalCommitted: false)
            case .failure(.invalidDecision):
                return .response(ResponseToExtension(
                    for: request,
                    payload: .error(.internalError)
                ), approvalCommitted: false)
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
