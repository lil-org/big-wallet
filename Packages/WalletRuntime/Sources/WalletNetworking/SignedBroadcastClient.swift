import Foundation
import WalletDomain

public struct SignedBroadcastClient: SignedTransactionBroadcasting {
    private let ethereum: EthereumBroadcastClient
    private let solana: SolanaRPCClient

    public nonisolated init(ethereum: EthereumBroadcastClient, solana: SolanaRPCClient) {
        self.ethereum = ethereum
        self.solana = solana
    }

    public func broadcast(_ request: BroadcastRequest) async -> BroadcastResult {
        switch request {
        case .ethereum(let signedTransaction, let expectedHash, let network):
            do {
                let hash = try await ethereum.sendSignedTransaction(signedTransaction, network: network.network)
                guard hash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
                    return .submissionUnknown(.ethereum(.transport))
                }
                return .accepted(expectedHash)
            } catch {
                let failure = error as? EthereumSendFailure ?? .transport
                switch failure {
                case .rpc(.notSubmitted):
                    return .notSubmitted(.ethereum(failure))
                case .rpc(.unknown), .transport:
                    return .submissionUnknown(.ethereum(failure))
                case .rpc(.serverError(let code, let message, _))
                    where code == -32_000 && message.range(of: "already known", options: .caseInsensitive) != nil:
                    return .submissionUnknown(.ethereum(failure))
                case .rpc(.serverError):
                    return .rejected(.ethereum(failure))
                }
            }
        case .solana(let signedTransaction, let expectedSignature, _, let endpoint, let options):
            do {
                let signature = try await solana.sendSignedTransaction(signedTransaction, endpoint: endpoint, sendOptions: options)
                guard signature == expectedSignature else { return .submissionUnknown(.solana(.unknown)) }
                return .accepted(expectedSignature)
            } catch {
                let failure = error as? Solana.SendTransactionError ?? .unknown
                switch failure {
                case .notSubmitted:
                    return .notSubmitted(.solana(failure))
                case .unknown:
                    return .submissionUnknown(.solana(failure))
                case .confirmationFailed(let signature, _, _), .confirmationTimedOut(let signature):
                    guard signature == expectedSignature else { return .submissionUnknown(.solana(.unknown)) }
                    return .confirmationFailed(transactionID: signature, failure: .solana(failure))
                case .rpcError(let message, let code) where code == -32_002 &&
                    message.range(of: "already", options: .caseInsensitive) != nil &&
                    message.range(of: "processed", options: .caseInsensitive) != nil:
                    return .submissionUnknown(.solana(failure))
                case .invalidMessage, .invalidSendOptions, .blockhashNotFound,
                     .unsupportedMultiSignature, .rpcError, .rpcUnavailable:
                    return .rejected(.solana(failure))
                }
            }
        }
    }
}
