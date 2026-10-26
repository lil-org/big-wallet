import Foundation
import WalletDomain

public struct EthereumBroadcastClient: Sendable {
    private let rpc: any EthereumRPCClient

    public init(rpc: any EthereumRPCClient) { self.rpc = rpc }

    public func sendSignedTransaction(_ signedTransaction: String, network: EthereumNetwork) async throws -> String {
        do {
            let result = try await rpc.sendRawTransaction(endpoint: network.rpcEndpoint, signedTxData: signedTransaction)
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as EthereumRPCError {
            try Task.checkCancellation()
            throw EthereumSendFailure.rpc(error)
        } catch {
            try Task.checkCancellation()
            throw EthereumSendFailure.transport
        }
    }

}
