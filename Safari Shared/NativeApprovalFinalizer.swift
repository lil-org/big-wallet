// ∅ 2026 lil org

import Foundation

enum NativeApprovalFinalizationResult: Equatable {
    case responseReady, pending, interruptionRequired
}

@MainActor
final class NativeApprovalFinalizer {

    static let shared = NativeApprovalFinalizer(
        store: ExtensionBridge.shared,
        requestProcessor: DappRequestProcessor()
    )

    private let store: NativeApprovalStore
    private let refreshWalletCatalog: () -> WalletReviewCatalog?
    private let makeSigner: DurableApprovalExecutor.SourceSignerFactory
    private let networkResolver: (String) -> EthereumNetwork?
    private let transactionNetworkResolver: (Int) -> ResolvedEthereumNetwork?
    private let executor: DurableApprovalExecutor

    init(
        store: NativeApprovalStore,
        requestProcessor: DappRequestProcessing,
        refreshWalletCatalog: @escaping () -> WalletReviewCatalog? = {
            guard WalletsManager.shared.start() else { return nil }
            return WalletsManager.shared.reviewCatalog()
        },
        makeSigner: DurableApprovalExecutor.SourceSignerFactory? = nil,
        networkResolver: @escaping (String) -> EthereumNetwork? = {
            Networks.withChainIdHex($0)
        },
        transactionNetworkResolver: @escaping (Int) -> ResolvedEthereumNetwork? = {
            Nodes.resolution(chainId: $0).resolvedNetwork
        },
        clock: @escaping () -> Date = Date.init,
        broadcastSender: (any ApprovedBroadcastSending)? = nil,
        broadcastTimeoutNanoseconds: UInt64 =
            DurableApprovalExecutor.defaultBroadcastTimeoutNanoseconds
    ) {
        self.store = store
        self.refreshWalletCatalog = refreshWalletCatalog
        self.makeSigner = makeSigner ?? { operation, authorityIsCurrent in
            WalletSigningSession.fromSource(
                operation: operation,
                authorityIsCurrent: authorityIsCurrent,
                clock: clock
            )
        }
        self.networkResolver = networkResolver
        self.transactionNetworkResolver = transactionNetworkResolver
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
        case .ownershipLost, .retryablePersistenceFailure, .abandoned:
            return .interruptionRequired
        }
    }

    private func resolve(_ consent: ReviewConsent) -> DurableApprovalExecutor.Resolution {
        if case .addEthereumChain(let action) = consent.intent.action {
            if let resolution = EthereumDappRequestProcessor.chainAdditionResolution(action.chainToAdd) {
                return .immediate(resolution)
            }
            return resolvedConsent(consent, context: .init(accounts: []))
        }
        CustomNetworkCache.shared.invalidate()
        let currentNetwork: ResolvedEthereumNetwork?
        if case .approveTransaction(let action) = consent.intent.action {
            guard let network = transactionNetworkResolver(action.chain.chainId) else {
                return .immediate(.failure(.internalError))
            }
            currentNetwork = network
        } else {
            currentNetwork = nil
        }
        guard let catalog = refreshWalletCatalog() else { return .abandon }
        let selectionNetwork: EthereumNetwork?
        switch (consent.intent.action, consent.decision) {
        case (.selectAccount(let action), .accountSelection(let selection)),
             (.switchAccount(let action), .accountSelection(let selection)):
            selectionNetwork = (selection.ethereumChainID ?? action.network?.chainIdHexString)
                .flatMap(networkResolver)
        default:
            selectionNetwork = nil
        }
        return resolvedConsent(consent, context: .init(
            accounts: catalog.orderedAccounts,
            selectionNetwork: selectionNetwork,
            transactionNetwork: currentNetwork
        ))
    }

    private func resolvedConsent(
        _ consent: ReviewConsent,
        context: ApprovalResolutionContext
    ) -> DurableApprovalExecutor.Resolution {
        switch consent.resolve(context: context) {
        case .success(let approval):
            return .approved(approval)
        case .failure(.accountUnavailable):
            return .immediate(missingSigningAccountResolution(for: consent.request))
        case .failure(.staleTransaction), .failure(.staleAccount):
            return .immediate(Self.staleResolution)
        case .failure(.invalidDecision):
            return .immediate(.failure(.internalError))
        }
    }

    private func missingSigningAccountResolution(for request: SafariRequest) -> ImmediateResolution {
        switch request.body {
        case .ethereum(let body):
            return body.method == .signTransaction
                ? Self.staleResolution
                : .failure(.init(message: Strings.somethingWentWrong))
        case .solana(let body):
            return .solanaAuthorizationDenied(publicKey: body.publicKey)
        case .unknown:
            return .failure(.internalError)
        }
    }

    private static var staleResolution: ImmediateResolution {
        .failure(ProviderResponseError(
            message: Strings.providerNotReady,
            code: 4100
        ))
    }
}
