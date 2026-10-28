import Foundation
import WalletDomain
import WalletAuthority

@MainActor
public final class WalletAuthoritySystem {
    public let runtime: AuthorityRuntime
    public var wallets: WalletsManager { runtime.wallets }
    public var credentials: WalletCredentials { runtime.credentials }
    public var requests: ExtensionBridge { runtime.requests }
    public var admission: DappRequestAdmission { runtime.admission }
    public var networks: NetworkResolver { runtime.networks }
    public var messages: AuthorityMessages { runtime.messages }
    public var metadata: WalletsMetadataService { runtime.metadata }

    public init(runtime: AuthorityRuntime) { self.runtime = runtime }

    public static func live(
        catalog: NetworkCatalog?, catalogOwnedChainIds: Set<Int>, decodedChainIds: Set<Int> = [],
        solanaEndpoints: any SolanaEndpointResolving, broadcaster: any SignedTransactionBroadcasting,
        preparation: TransactionApprovalOperations, storage: AuthorityStorageConfiguration, messages: AuthorityMessages
    ) -> WalletAuthoritySystem {
        WalletAuthoritySystem(runtime: .live(catalog: catalog, catalogOwnedChainIds: catalogOwnedChainIds,
            decodedChainIds: decodedChainIds, solanaEndpoints: solanaEndpoints, broadcaster: broadcaster,
            preparation: preparation, storage: storage, messages: messages))
    }

    public func makeNativeApprovalCoordinator(handle: RequestHandle, nativeDeliveryNonce: NativeDeliveryNonce) -> NativeApprovalCoordinator {
        NativeApprovalCoordinator(authority: runtime.makeNativeApprovalAuthority(handle: handle, nativeDeliveryNonce: nativeDeliveryNonce))
    }

    public func makePopupRequestSessions(presentation: PopupApprovalStatePresenter.Environment,
        loadTransactionContext: @escaping @MainActor @Sendable (SendTransactionAction) async -> String?) -> PopupRequestSessions {
        PopupRequestSessions(authority: runtime.makePopupApprovalAuthority(
            approvalSubjectTitle: presentation.approvalSubjectTitle, loadTransactionContext: loadTransactionContext),
            presentation: presentation, messages: messages)
    }

    public func error(_ kind: AuthorityRuntime.ErrorKind) -> ProviderResponseError { runtime.error(kind) }
    nonisolated public func invalidateNetworkCache() { runtime.invalidateNetworkCache() }
    public func recordReviewRequest(at date: Date) { runtime.recordReviewRequest(at: date) }

#if os(iOS) || os(visionOS)
    public func startVaultReconciliation(backgroundTask: @escaping AuthorityRuntime.BackgroundTask,
                                         protectedDataDidBecomeAvailable: Notification.Name) async {
        await runtime.startVaultReconciliation(backgroundTask: backgroundTask, protectedDataDidBecomeAvailable: protectedDataDidBecomeAvailable)
    }
    public func reconcileVault() async { await runtime.reconcileVault() }
    public func waitForVaultReconciliation() async { await runtime.waitForVaultReconciliation() }
#endif
}
