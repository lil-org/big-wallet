import Foundation
import WalletDomain

public struct PublicRPCForwarder: PublicRPCForwarding {
    private let service: SafariRPCService
    private let send: @Sendable (EthereumRPCEndpoint, ValidatedRPCRequest, SafariRPCExecution) async throws -> RPCResponseToExtension
    private let network: @Sendable (Int) -> ResolvedEthereumNetwork?

    public init(service: SafariRPCService, client: SafariRPCClient, network: @escaping @Sendable (Int) -> ResolvedEthereumNetwork?) {
        self.service = service
        self.send = { endpoint, request, execution in
            try await client.send(endpoint: endpoint, request: request, execution: execution)
        }
        self.network = network
    }

    init(
        service: SafariRPCService,
        network: @escaping @Sendable (Int) -> ResolvedEthereumNetwork?,
        send: @escaping @Sendable (EthereumRPCEndpoint, ValidatedRPCRequest, SafariRPCExecution) async throws -> RPCResponseToExtension
    ) {
        self.service = service
        self.network = network
        self.send = send
    }

    public func forward(id: Int, chainId: String, body: String, scope: RPCScope) async -> RPCResponseToExtension {
        await service.perform(id: id, body: body, scope: scope) { request, execution in
            guard let chainId = Int(hexString: chainId), chainId > 0 else {
                throw SafariRPCFailure.invalidRequest
            }
            guard let network = network(chainId) else { throw SafariRPCFailure.transport }
            try execution.checkCancellationAndDeadline()
            return try await send(network.rpcEndpoint, request, execution)
        }
    }
}
