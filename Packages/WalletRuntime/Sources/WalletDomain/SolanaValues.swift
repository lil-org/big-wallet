import Foundation

public enum Solana {
    public enum Cluster: String, CaseIterable, Hashable, Codable, Sendable {
        case mainnetBeta
        case devnet
        case testnet

        public var displayName: String {
            switch self {
            case .mainnetBeta:
                return "Mainnet"
            case .devnet:
                return "Devnet"
            case .testnet:
                return "Testnet"
            }
        }

        package var alchemyNetwork: String? {
            switch self {
            case .mainnetBeta:
                return "solana-mainnet"
            case .devnet:
                return "solana-devnet"
            case .testnet:
                return nil
            }
        }

        public var rpcSource: RPCSource {
            return alchemyNetwork == nil ? .publicFallback : .alchemy
        }

        public init?(clusterHint: String) {
            switch clusterHint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "mainnet", "mainnet-beta", "mainnetbeta", "solana:mainnet":
                self = .mainnetBeta
            case "devnet", "solana:devnet":
                self = .devnet
            case "testnet", "solana:testnet":
                self = .testnet
            default:
                return nil
            }
        }
    }


    public enum SendTransactionError: Error, Equatable, Sendable {
        case invalidMessage
        case unsupportedMultiSignature
        case blockhashNotFound
        case invalidSendOptions
        case confirmationFailed(signature: String, message: String, code: Int?)
        case confirmationTimedOut(signature: String)
        case rpcError(message: String, code: Int?)
        case rpcUnavailable
        case notSubmitted
        case unknown
    }


    public enum Commitment: String, Decodable, Sendable {
        case processed
        case confirmed
        case finalized

        public func satisfies(_ requestedCommitment: Commitment) -> Bool {
            return confirmationRank >= requestedCommitment.confirmationRank
        }

        private var confirmationRank: Int {
            switch self {
            case .processed:
                return 0
            case .confirmed:
                return 1
            case .finalized:
                return 2
            }
        }
    }


    public struct ParsedTransaction: Sendable {
        public let transactionData: Data
        public let messageData: Data
        public let messageRange: Range<Data.Index>
        public let parsedMessage: SolanaWireMessage
        public let signaturesStartIndex: Data.Index

        package init(transactionData: Data, messageData: Data, messageRange: Range<Data.Index>, parsedMessage: SolanaWireMessage, signaturesStartIndex: Data.Index) {
            self.transactionData = transactionData
            self.messageData = messageData
            self.messageRange = messageRange
            self.parsedMessage = parsedMessage
            self.signaturesStartIndex = signaturesStartIndex
        }
    }


    public struct PreparedSignAndSendTransaction: Sendable {
        public let parsedTransaction: ParsedTransaction
        public let signerSignatureRange: Range<Data.Index>

        package init(parsedTransaction: ParsedTransaction, signerSignatureRange: Range<Data.Index>) {
            self.parsedTransaction = parsedTransaction
            self.signerSignatureRange = signerSignatureRange
        }
    }


    public struct PreparedLegacySignAndSendTransaction: Sendable {
        public let approvalMessage: String
        public let preparedMessage: SolanaPreparedTransactionMessage

        package init(approvalMessage: String, preparedMessage: SolanaPreparedTransactionMessage) {
            self.approvalMessage = approvalMessage
            self.preparedMessage = preparedMessage
        }
    }


    public struct PreparedSerializedTransaction: Sendable {
        public let approvalMessage: String
        package let preparedTransaction: PreparedSignAndSendTransaction

        public var preparedMessage: SolanaPreparedTransactionMessage {
            return SolanaPreparedTransactionMessage(messageData: preparedTransaction.parsedTransaction.messageData,
                                                    parsedMessage: preparedTransaction.parsedTransaction.parsedMessage)
        }

        package init(approvalMessage: String, preparedTransaction: PreparedSignAndSendTransaction) {
            self.approvalMessage = approvalMessage
            self.preparedTransaction = preparedTransaction
        }
    }


    public struct PreparedSendOptions: Sendable {
        public let clusterHint: Cluster?
        public let preflightCommitment: Commitment?
        public let maxRetries: Int?
        public let minContextSlot: Int?
        public let confirmationCommitment: Commitment?

        public init(
            clusterHint: Cluster? = nil,
            preflightCommitment: Commitment? = nil,
            maxRetries: Int? = nil,
            minContextSlot: Int? = nil,
            confirmationCommitment: Commitment? = nil
        ) {
            self.clusterHint = clusterHint
            self.preflightCommitment = preflightCommitment
            self.maxRetries = maxRetries
            self.minContextSlot = minContextSlot
            self.confirmationCommitment = confirmationCommitment
        }

        public var rpcOptions: [String: Any] {
            var options: [String: Any] = [
                "encoding": "base64",
                "skipPreflight": false,
            ]
            if let preflightCommitment {
                options["preflightCommitment"] = preflightCommitment.rawValue
            }
            if let maxRetries {
                options["maxRetries"] = maxRetries
            }
            if let minContextSlot {
                options["minContextSlot"] = minContextSlot
            }
            return options
        }
    }


    public enum RPCSource: Equatable, Sendable {
        case alchemy
        case publicFallback

    }


    public static let maxWirePayloadLength = 1_232
    public static let maxBase58EncodedWirePayloadLength = 1_683
}
