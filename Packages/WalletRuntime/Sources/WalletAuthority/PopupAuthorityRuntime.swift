import Foundation
import WalletDomain

@MainActor
public final class PopupAuthorityRuntime {
    struct Dependencies {
        var makeVault: @MainActor (AuthorityRuntimeConfiguration, AuthorityComposition.Dependencies) -> SafariApprovalVault = {
            SafariApprovalVault(fileURL: $0.storage.containerURL?.appendingPathComponent("SafariApprovalVault.v1"),
                clock: $1.clock, hooks: $1.hooks)
        }
        var makeMetadata: @MainActor () -> WalletsMetadataService = { .live() }
    }

    public let requests: ExtensionBridge
    public let admission: DappRequestAdmission
    public let networks: NetworkResolver
    public let messages: AuthorityMessages
    private let vault: SafariApprovalVault
    private let metadata: WalletsMetadataService
    private let executionEnvironment: DurableApprovalExecutor.Environment
    private let preparation: TransactionApprovalOperations
    private let definitionResult: @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult
    private nonisolated let invalidateCache: @Sendable () -> Void

    public static func live(configuration: AuthorityRuntimeConfiguration,
                            solanaEndpoints: any SolanaEndpointResolving,
                            broadcaster: any SignedTransactionBroadcasting,
                            preparation: TransactionApprovalOperations) -> PopupAuthorityRuntime {
        PopupAuthorityRuntime(composition: .init(configuration: configuration), solanaEndpoints: solanaEndpoints,
            broadcaster: broadcaster, preparation: preparation, dependencies: .init())
    }

    init(composition: AuthorityComposition, solanaEndpoints: any SolanaEndpointResolving,
         broadcaster: any SignedTransactionBroadcasting, preparation: TransactionApprovalOperations,
         dependencies: Dependencies) {
        requests = composition.requests
        networks = composition.networks
        messages = composition.configuration.messages
        definitionResult = composition.dependencies.definitionResult
        invalidateCache = composition.dependencies.invalidateCache
        self.preparation = preparation
        metadata = dependencies.makeMetadata()
        let vault = dependencies.makeVault(composition.configuration, composition.dependencies)
        self.vault = vault
        let processor = composition.makeRequestProcessor(solanaEndpoints: solanaEndpoints)
        executionEnvironment = .init(requestProcessor: processor, broadcaster: broadcaster,
            hooks: composition.dependencies.hooks, clock: composition.dependencies.clock)
        admission = DappRequestAdmission(store: composition.requests, requestProcessor: processor,
            reviewCatalog: { await awaitBackgroundOperation { vault.reviewCatalog() } ?? nil },
            messages: composition.configuration.messages)
    }

    public func accountName(walletID: String, account: WalletAccount) -> String? {
        metadata.getAccountName(walletId: walletID, account: account)
    }

    public func makePopupApprovalAuthority(
        approvalSubjectTitle: @escaping @MainActor @Sendable (ApprovalSubject) -> String,
        loadTransactionContext: @escaping @MainActor @Sendable (SendTransactionAction) async -> String?
    ) -> PopupApprovalAuthority {
        PopupApprovalAuthority(store: requests,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { [vault] in await awaitBackgroundOperation { vault.reviewCatalog() } ?? nil },
                approvalCatalog: { [vault] in await awaitBackgroundOperation { vault.approvalCatalog() } ?? nil },
                unlockWallets: { [vault] in await vault.unlockResult(reason: $0, scope: $1) },
                reloadMetadata: { [metadata] in metadata.reload() }),
            loadsTransactionContext: true, transactionApprovalOperations: preparation,
            invalidateNetworkCache: invalidateCache,
            selectionNetworkResolver: { [networks] in networks.network(chainIdHex: $0) },
            approvalNetworkResolver: networks.approvalResolution,
            executionEnvironment: executionEnvironment, approvalSubjectTitle: approvalSubjectTitle,
            customDefinitionResult: definitionResult, messages: messages, loadTransactionContext: loadTransactionContext)
    }

    nonisolated public func invalidateNetworkCache() { invalidateCache() }
}
