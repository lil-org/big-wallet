import Foundation
import WalletDomain
import WalletNetworking

func networkingContract(preparation: EthereumTransactionPreparation, endpoint: EthereumRPCEndpoint,
    request: ValidatedRPCRequest, client: SafariRPCClient, scope: RPCScope,
    forwarder: any PublicRPCForwarding) async -> SafariRPCService.Statistics {
    _ = preparation.makePreparationOperations()
    _ = endpoint.url
    _ = request.id
    _ = client
    _ = scope
    _ = await forwarder.forward(id: request.id, chainId: "0x1", body: "{}", scope: scope, onAdmissionDecision: {})
    _ = await forwarder.forward(id: request.id, chainId: "0x1", body: "{}", scope: scope)
    let service = SafariRPCService()
    return await service.statistics
}
