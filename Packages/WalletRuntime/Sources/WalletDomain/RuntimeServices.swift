import Foundation

public protocol AuthorityNetworkCatalog: Sendable {
    func resolution(chainId: Int) -> EthereumNetworkResolution
    func approvalResolution(chainId: Int) -> ApprovalNetworkResolution
    func network(chainIdHex: String?) -> EthereumNetwork?
    var allNetworks: [EthereumNetwork] { get }
}

public protocol TransactionPreparing: Sendable {
    func prepareTransaction(
        _ transaction: Transaction,
        forceGasCheck: Bool,
        network: EthereumNetwork
    ) -> AsyncThrowingStream<TransactionPreparationEvent, Error>

    func preflightTransactionFee(
        _ transaction: Transaction,
        network: EthereumNetwork
    ) async throws -> TransactionFeePreflightResult
}

public enum BroadcastRequest: Sendable {
    case ethereum(signedTransaction: String, expectedHash: String, network: ResolvedEthereumNetwork)
    case solana(signedTransaction: String, expectedSignature: String, cluster: Solana.Cluster, endpoint: SolanaRPCEndpoint, options: Solana.PreparedSendOptions)
}

public enum BroadcastFailure: Sendable, Equatable {
    case ethereum(EthereumSendFailure)
    case solana(Solana.SendTransactionError)
}

public enum BroadcastResult: Sendable, Equatable {
    case accepted(String)
    case rejected(BroadcastFailure)
    case notSubmitted(BroadcastFailure)
    case submissionUnknown(BroadcastFailure)
    case confirmationFailed(transactionID: String, failure: BroadcastFailure)
}

@MainActor
public protocol SignedTransactionBroadcasting: Sendable {
    func broadcast(_ request: BroadcastRequest) async -> BroadcastResult
}
