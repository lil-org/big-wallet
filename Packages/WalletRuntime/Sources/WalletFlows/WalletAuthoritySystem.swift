import Foundation
import WalletDomain
import WalletAuthority

@MainActor
public final class WalletAuthoritySystem {
    private let runtime: AuthorityRuntime
    public var wallets: WalletsManager { runtime.wallets }
    public var credentials: WalletCredentials { runtime.credentials }
    public var requests: ExtensionBridge { runtime.requests }
    public var networks: NetworkResolver { runtime.networks }
    public var messages: AuthorityMessages { runtime.messages }
    public var metadata: WalletsMetadataService { runtime.metadata }

    public init(runtime: AuthorityRuntime) { self.runtime = runtime }

#if os(macOS)
    public static func live(configuration: AuthorityRuntimeConfiguration,
                            solanaEndpoints: any SolanaEndpointResolving,
                            broadcaster: any SignedTransactionBroadcasting) -> WalletAuthoritySystem {
        WalletAuthoritySystem(runtime: .live(configuration: configuration,
            solanaEndpoints: solanaEndpoints, broadcaster: broadcaster))
    }

    public func makeNativeApprovalCoordinator(handle: RequestHandle, nativeDeliveryNonce: NativeDeliveryNonce) -> NativeApprovalCoordinator {
        NativeApprovalCoordinator(authority: runtime.makeNativeApprovalAuthority(handle: handle, nativeDeliveryNonce: nativeDeliveryNonce))
    }
#else
    public static func live(configuration: AuthorityRuntimeConfiguration) -> WalletAuthoritySystem {
        WalletAuthoritySystem(runtime: .live(configuration: configuration))
    }
#endif

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
