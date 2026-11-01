import Foundation
import WalletDomain

@MainActor
public final class NativeTransportRuntime {
    public let requests: ExtensionBridge
    public let admission: DappRequestAdmission
    public let networks: NetworkResolver
    public let messages: AuthorityMessages
    private nonisolated let invalidateCache: @Sendable () -> Void

    public static func live(configuration: AuthorityRuntimeConfiguration,
                            solanaEndpoints: any SolanaEndpointResolving) -> NativeTransportRuntime {
        NativeTransportRuntime(composition: .init(configuration: configuration), solanaEndpoints: solanaEndpoints)
    }

    init(composition: AuthorityComposition, solanaEndpoints: any SolanaEndpointResolving) {
        requests = composition.requests
        networks = composition.networks
        messages = composition.configuration.messages
        invalidateCache = composition.dependencies.invalidateCache
        admission = DappRequestAdmission(store: composition.requests,
            requestProcessor: composition.makeRequestProcessor(solanaEndpoints: solanaEndpoints),
            messages: composition.configuration.messages)
    }

    nonisolated public func invalidateNetworkCache() { invalidateCache() }
}
