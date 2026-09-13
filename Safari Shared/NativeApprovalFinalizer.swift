// ∅ 2026 lil org

import Foundation

enum NativeApprovalFinalizationResult: Equatable {
    case responseReady, pending, unavailable
}

@MainActor
final class NativeApprovalFinalizer {

    nonisolated static let maximumTransactionDecisionAge: TimeInterval = 30

    static let shared = NativeApprovalFinalizer(
        store: ExtensionBridge.shared,
        requestProcessor: ProductionDappRequestProcessor()
    )

    private let store: NativeApprovalStore
    private let requestProcessor: DappRequestProcessing
    private let startWalletsManager: () -> Bool
    private let reloadWalletsManager: () -> Bool
    private let accountResolver: (DappApprovalDecision.AccountIdentity) ->
        SpecificWalletAccount?
    private let networkResolver: (String) -> EthereumNetwork?
    private let clock: () -> Date
    private let executor: DurableApprovalExecutor
    private var didStartWalletsManager = false

    init(
        store: NativeApprovalStore,
        requestProcessor: DappRequestProcessing,
        walletManagerStart: @escaping () -> Bool = {
            WalletsManager.shared.start()
        },
        walletManagerReload: @escaping () -> Bool = {
            WalletsManager.shared.reloadFromStore()
        },
        accountResolver: ((DappApprovalDecision.AccountIdentity) ->
            SpecificWalletAccount?)? = nil,
        networkResolver: @escaping (String) -> EthereumNetwork? = {
            Networks.withChainIdHex($0)
        },
        clock: @escaping () -> Date = Date.init,
        broadcastTimeoutNanoseconds: UInt64 =
            DurableApprovalExecutor.defaultBroadcastTimeoutNanoseconds
    ) {
        self.store = store
        self.requestProcessor = requestProcessor
        startWalletsManager = walletManagerStart
        reloadWalletsManager = walletManagerReload
        self.accountResolver = accountResolver ?? { identity in
            guard let coin = WalletCoin.correspondingToInpageProvider(
                      identity.provider
                  ),
                  let wallet = WalletsManager.shared.currentWallet(
                      id: identity.walletID
                  ),
                  let account = wallet.accounts.first(where: {
                      $0.coin == coin && $0.address == identity.address &&
                          $0.derivationPath == identity.derivationPath
                  }) else { return nil }
            return SpecificWalletAccount(
                walletId: identity.walletID,
                account: account
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

    func finalize(
        handle: ExtensionBridge.Handle
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
        switch snapshot.phase {
        case .responded:
            return .responseReady
        case .approving:
            return .pending
        case .queued:
            guard snapshot.nativeDecisionStaged,
                  let request = snapshot.request else { return .pending }
            return await claimAndFinalize(
                snapshot: snapshot,
                request: request
            )
        }
    }

    private func claimAndFinalize(
        snapshot: ExtensionBridge.Snapshot,
        request: SafariRequest
    ) async -> NativeApprovalFinalizationResult {
        let nativeClaim: ExtensionBridge.NativeDecisionClaim
        let claimResult = await store.claimExecutableNativeDecision(
            handle: snapshot.handle
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

        guard let executionContext = nativeClaim.executionContext else {
            return await releaseClaimForRetry(nativeClaim.approvalClaim)
        }
        let now = clock()
        let age = now.timeIntervalSince(executionContext.observedAt)
        guard age >= 0,
              now < executionContext.executionDeadline else {
            return await releaseClaimForRetry(nativeClaim.approvalClaim)
        }

        guard transactionDecisionIsFresh(nativeClaim, request: request) else {
            return await completeStaleTransactionDecision(
                nativeClaim,
                request: request,
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
            guard prepareWallets() else {
                return await releaseClaimForRetry(
                    nativeClaim.approvalClaim
                )
            }
            CustomNetworkCache.shared.invalidate()
            walletAccess = SourceWalletAccess.shared
            preparation = requestProcessor.prepare(
                request,
                walletAccess: SourceWalletAccess.shared
            )
        }
        switch preparation {
        case .response(let response):
            return await execute(
                claim: nativeClaim.approvalClaim,
                markingApprovalCommitted: false,
                executionContext: executionContext
            ) { .response(response) }
        case .approval(let action):
            if case (.approveTransaction(let transactionAction),
                     .transaction(let execution)) =
                    (action, nativeClaim.decision),
               execution.applying(to: transactionAction) == nil {
                return await execute(
                    claim: nativeClaim.approvalClaim,
                    markingApprovalCommitted: false,
                    executionContext: executionContext
                ) {
                    .response(Self.staleResponse(for: request))
                }
            }
            guard canExecute(
                action: action,
                decision: nativeClaim.decision
            ) else {
                return await persistInternalError(
                    claim: nativeClaim.approvalClaim,
                    request: request,
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
                executionContext: executionContext
            ) {
                await self.requestProcessor.execute(
                    request: request,
                    action: action,
                    decision: nativeClaim.decision,
                    walletAccess: walletAccess
                )
            }
        }
    }

    private func transactionDecisionIsFresh(
        _ nativeClaim: ExtensionBridge.NativeDecisionClaim,
        request: SafariRequest
    ) -> Bool {
        guard requestRequiresFreshTransactionDecision(request) else {
            return true
        }
        let age = clock().timeIntervalSince(nativeClaim.stagedAt)
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
        _ nativeClaim: ExtensionBridge.NativeDecisionClaim,
        request: SafariRequest,
        executionContext: ExtensionBridge.NativeExecutionContext
    ) async -> NativeApprovalFinalizationResult {
        await execute(
            claim: nativeClaim.approvalClaim,
            markingApprovalCommitted: false,
            executionContext: executionContext
        ) {
            .response(Self.staleResponse(for: request))
        }
    }

    private func prepareWallets() -> Bool {
        if didStartWalletsManager {
            return reloadWalletsManager()
        }
        didStartWalletsManager = true
        return startWalletsManager()
    }

    private func canExecute(
        action: DappRequestAction,
        decision: DappApprovalDecision
    ) -> Bool {
        switch (action, decision) {
        case (.selectAccount(let action), .accountSelection(let selection)),
             (.switchAccount(let action), .accountSelection(let selection)):
            guard let accounts = resolveAccounts(
                      selection.accounts,
                      requiredCoin: action.coinType
                  ) else { return false }
            let selectedChainID = selection.ethereumChainID ??
                action.network?.chainIdHexString
            let network = selectedChainID.flatMap(networkResolver)
            let resolvedAction = SelectAccountAction(
                coinType: action.coinType,
                selectedAccounts: Set(accounts),
                initiallyConnectedProviders: action.initiallyConnectedProviders,
                network: network
            )
            guard selectedChainID == nil || network != nil,
                  !(accounts.isEmpty && action.initiallyConnectedProviders.isEmpty),
                  accounts.isEmpty || resolvedAction.canSubmitSelection(
                      network: network
                  )
            else { return false }
            return true
        case (.approveMessage(let action), .message(let approval)):
            return (action.solanaClusterOptions != nil) == (approval.solanaCluster != nil)
        case (.approveTransaction(let action), .transaction(let execution)):
            guard let transaction = execution.applying(to: action),
                  transaction.isReadyForApproval(on: action.chain) else { return false }
            return true
        case (.addEthereumChain, .addEthereumChain):
            return true
        default:
            return false
        }
    }

    private func resolveAccounts(
        _ identities: [DappApprovalDecision.AccountIdentity],
        requiredCoin: WalletCoin?
    ) -> [SpecificWalletAccount]? {
        var result = [SpecificWalletAccount]()
        var coins = Set<WalletCoin>()
        for identity in identities {
            guard let coin = WalletCoin.correspondingToInpageProvider(
                      identity.provider
                  ),
                  requiredCoin == nil || requiredCoin == coin,
                  coins.insert(coin).inserted,
                  let account = accountResolver(identity),
                  account.walletId == identity.walletID,
                  account.account.coin == coin,
                  account.account.address == identity.address,
                  account.account.derivationPath == identity.derivationPath else { return nil }
            result.append(account)
        }
        return result
    }

    private func persistInternalError(
        claim: ExtensionBridge.ApprovalClaim,
        request: SafariRequest,
        executionContext: ExtensionBridge.NativeExecutionContext
    ) async -> NativeApprovalFinalizationResult {
        return await execute(
            claim: claim,
            markingApprovalCommitted: false,
            executionContext: executionContext
        ) {
            .response(ResponseToExtension(
                for: request,
                payload: .error(.internalError)
            ))
        }
    }

    private func releaseClaimForRetry(
        _ claim: ExtensionBridge.ApprovalClaim
    ) async -> NativeApprovalFinalizationResult {
        switch await store.release(claim: claim) {
        case .persisted:
            return .pending
        case .ownershipLost:
            return await reconcileOwnershipLoss(handle: claim.handle)
        case .retryablePersistenceFailure:
            return .unavailable
        }
    }

    private func execute(
        claim: ExtensionBridge.ApprovalClaim,
        markingApprovalCommitted: Bool = true,
        preExecutionValidation: (() -> ResponseToExtension?)? = nil,
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
        case .ownershipLost:
            return await reconcileOwnershipLoss(handle: claim.handle)
        case .beginRetryablePersistenceFailure:
            return await releaseClaimForRetry(claim)
        case .retryablePersistenceFailure:
            return .unavailable
        case .rolledBack:
            return .pending
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
