import Foundation
import WalletDomain
import WalletNetworking

func networkingContract(preparation: EthereumTransactionPreparation, endpoint: EthereumRPCEndpoint,
    request: ValidatedRPCRequest, client: SafariRPCClient, scope: RPCScope) async -> SafariRPCService.Statistics {
    _ = preparation.makePreparationOperations()
    _ = endpoint.url
    _ = request.id
    _ = client
    _ = scope
    let service = SafariRPCService()
    return await service.statistics
}
