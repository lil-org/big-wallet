// ∅ 2026 lil org

import Foundation
import WalletCore

struct SolanaWireMessage {
    let requiredSignaturesCount: Int
    let accountKeys: [Data]
    let blockhashRange: Range<Data.Index>
}

enum SolanaWireMessageParser {
    private static let publicKeyLength = 32
    private static let blockhashLength = 32
    private static let versionedMessageMask: UInt8 = 0x80
    private static let versionMask: UInt8 = 0x7f
    private static let supportedVersionedMessageVersion: UInt8 = 0
    private static let maxReferencedAccountCount = Int(UInt8.max) + 1

    private struct Prefix {
        let requiredSignaturesCount: Int
        let readOnlySignedAccountsCount: Int
        let readOnlyUnsignedAccountsCount: Int
        let accountCountOffset: Int
        let isVersioned: Bool
    }

    private struct ParsedInstructions {
        let highestAccountIndex: Int?
        let highestProgramIdIndex: Int?
    }

    static func parse(_ messageData: Data) -> SolanaWireMessage? {
        guard let prefix = prefix(for: messageData),
              let accountCountIndex = messageData.index(messageData.startIndex, offsetBy: prefix.accountCountOffset, limitedBy: messageData.endIndex),
              let decodedLength = messageData.decodeLength(startingAt: accountCountIndex)
        else { return nil }

        guard decodedLength.length >= prefix.requiredSignaturesCount else { return nil }
        guard prefix.readOnlySignedAccountsCount < prefix.requiredSignaturesCount else { return nil }
        guard prefix.readOnlyUnsignedAccountsCount <= decodedLength.length - prefix.requiredSignaturesCount else { return nil }

        let (accountKeysLength, didOverflow) = decodedLength.length.multipliedReportingOverflow(by: publicKeyLength)
        guard !didOverflow,
              let accountKeysEndIndex = messageData.index(decodedLength.nextIndex, offsetBy: accountKeysLength, limitedBy: messageData.endIndex),
              let blockhashEndIndex = messageData.index(accountKeysEndIndex, offsetBy: blockhashLength, limitedBy: messageData.endIndex)
        else { return nil }

        var cursor = blockhashEndIndex
        guard let parsedInstructions = parseInstructions(in: messageData, cursor: &cursor) else { return nil }

        let loadedAddressCount: Int
        if prefix.isVersioned {
            guard let parsedLoadedAddressCount = parseAddressTableLookups(in: messageData, cursor: &cursor) else { return nil }
            loadedAddressCount = parsedLoadedAddressCount
        } else {
            loadedAddressCount = 0
        }

        guard cursor == messageData.endIndex else { return nil }

        let (totalAddressCount, addressCountOverflow) = decodedLength.length.addingReportingOverflow(loadedAddressCount)
        guard !addressCountOverflow else { return nil }
        guard totalAddressCount <= maxReferencedAccountCount else { return nil }
        if let highestProgramIdIndex = parsedInstructions.highestProgramIdIndex {
            guard highestProgramIdIndex < decodedLength.length else { return nil }
        }
        if let highestInstructionAccountIndex = parsedInstructions.highestAccountIndex {
            guard highestInstructionAccountIndex < totalAddressCount else { return nil }
        }

        var accountKeys = [Data]()
        accountKeys.reserveCapacity(decodedLength.length)

        var accountKeyStartIndex = decodedLength.nextIndex
        for _ in 0..<decodedLength.length {
            guard let accountKeyEndIndex = messageData.index(accountKeyStartIndex, offsetBy: publicKeyLength, limitedBy: accountKeysEndIndex)
            else {
                return nil
            }

            accountKeys.append(messageData.subdata(in: accountKeyStartIndex..<accountKeyEndIndex))
            accountKeyStartIndex = accountKeyEndIndex
        }

        guard accountKeyStartIndex == accountKeysEndIndex else { return nil }

        return SolanaWireMessage(requiredSignaturesCount: prefix.requiredSignaturesCount,
                                 accountKeys: accountKeys,
                                 blockhashRange: accountKeysEndIndex..<blockhashEndIndex)
    }

    private static func prefix(for messageData: Data) -> Prefix? {
        guard let firstByte = messageData.first else { return nil }
        if firstByte & versionedMessageMask == 0 {
            guard let readOnlySignedAccountsCount = byte(at: 1, in: messageData),
                  let readOnlyUnsignedAccountsCount = byte(at: 2, in: messageData)
            else { return nil }

            return Prefix(requiredSignaturesCount: Int(firstByte),
                          readOnlySignedAccountsCount: Int(readOnlySignedAccountsCount),
                          readOnlyUnsignedAccountsCount: Int(readOnlyUnsignedAccountsCount),
                          accountCountOffset: 3,
                          isVersioned: false)
        } else {
            guard firstByte & versionMask == supportedVersionedMessageVersion else { return nil }

            guard let requiredSignaturesCount = byte(at: 1, in: messageData),
                  let readOnlySignedAccountsCount = byte(at: 2, in: messageData),
                  let readOnlyUnsignedAccountsCount = byte(at: 3, in: messageData)
            else {
                return nil
            }
            return Prefix(requiredSignaturesCount: Int(requiredSignaturesCount),
                          readOnlySignedAccountsCount: Int(readOnlySignedAccountsCount),
                          readOnlyUnsignedAccountsCount: Int(readOnlyUnsignedAccountsCount),
                          accountCountOffset: 4,
                          isVersioned: true)
        }
    }

    private static func parseInstructions(in messageData: Data, cursor: inout Data.Index) -> ParsedInstructions? {
        guard let instructionCount = readLength(in: messageData, cursor: &cursor) else { return nil }

        var highestAccountIndex: Int?
        var highestProgramIdIndex: Int?
        for _ in 0..<instructionCount {
            guard let programIdIndex = readByte(in: messageData, cursor: &cursor),
                  let accountIndexCount = readLength(in: messageData, cursor: &cursor),
                  let accountIndicesEndIndex = messageData.index(cursor, offsetBy: accountIndexCount, limitedBy: messageData.endIndex)
            else {
                return nil
            }

            guard programIdIndex != 0 else { return nil }

            updateHighestIndex(&highestProgramIdIndex, with: programIdIndex)
            var accountIndexCursor = cursor
            while accountIndexCursor < accountIndicesEndIndex {
                updateHighestIndex(&highestAccountIndex, with: messageData[accountIndexCursor])
                accountIndexCursor = messageData.index(after: accountIndexCursor)
            }
            cursor = accountIndicesEndIndex

            guard let instructionDataLength = readLength(in: messageData, cursor: &cursor),
                  advance(&cursor, by: instructionDataLength, in: messageData)
            else {
                return nil
            }
        }

        return ParsedInstructions(highestAccountIndex: highestAccountIndex,
                                  highestProgramIdIndex: highestProgramIdIndex)
    }

    private static func updateHighestIndex(_ highestIndex: inout Int?, with index: UInt8) {
        let index = Int(index)
        highestIndex = highestIndex.map { max($0, index) } ?? index
    }

    private static func parseAddressTableLookups(in messageData: Data, cursor: inout Data.Index) -> Int? {
        guard let lookupCount = readLength(in: messageData, cursor: &cursor) else { return nil }

        var loadedAddressCount = 0
        for _ in 0..<lookupCount {
            guard advance(&cursor, by: publicKeyLength, in: messageData),
                  let writableIndexCount = readLength(in: messageData, cursor: &cursor),
                  advance(&cursor, by: writableIndexCount, in: messageData),
                  let readOnlyIndexCount = readLength(in: messageData, cursor: &cursor),
                  advance(&cursor, by: readOnlyIndexCount, in: messageData)
            else {
                return nil
            }

            let (lookupLoadedAddressCount, lookupOverflow) = writableIndexCount.addingReportingOverflow(readOnlyIndexCount)
            guard !lookupOverflow, lookupLoadedAddressCount > 0 else { return nil }
            let (combinedLoadedAddressCount, loadedAddressOverflow) = loadedAddressCount.addingReportingOverflow(lookupLoadedAddressCount)
            guard !loadedAddressOverflow else { return nil }
            loadedAddressCount = combinedLoadedAddressCount
        }

        return loadedAddressCount
    }

    private static func readLength(in messageData: Data, cursor: inout Data.Index) -> Int? {
        guard let decodedLength = messageData.decodeLength(startingAt: cursor) else { return nil }
        cursor = decodedLength.nextIndex
        return decodedLength.length
    }

    private static func readByte(in messageData: Data, cursor: inout Data.Index) -> UInt8? {
        guard cursor < messageData.endIndex else { return nil }
        let byte = messageData[cursor]
        cursor = messageData.index(after: cursor)
        return byte
    }

    private static func advance(_ cursor: inout Data.Index, by count: Int, in messageData: Data) -> Bool {
        guard count >= 0,
              let nextIndex = messageData.index(cursor, offsetBy: count, limitedBy: messageData.endIndex)
        else {
            return false
        }

        cursor = nextIndex
        return true
    }

    private static func byte(at offset: Int, in messageData: Data) -> UInt8? {
        guard let index = messageData.index(messageData.startIndex, offsetBy: offset, limitedBy: messageData.endIndex),
              index < messageData.endIndex
        else {
            return nil
        }

        return messageData[index]
    }
}

final class Solana {

    enum Cluster: String, CaseIterable {
        case mainnetBeta
        case devnet
        case testnet

        var displayName: String {
            switch self {
            case .mainnetBeta:
                return "Mainnet"
            case .devnet:
                return "Devnet"
            case .testnet:
                return "Testnet"
            }
        }

        fileprivate var rpcConfigurationKey: String {
            switch self {
            case .mainnetBeta:
                return "SolanaMainnetRPCURL"
            case .devnet:
                return "SolanaDevnetRPCURL"
            case .testnet:
                return "SolanaTestnetRPCURL"
            }
        }

        fileprivate var publicRPCFallbackURLString: String {
            switch self {
            case .mainnetBeta:
                return "https://api.mainnet.solana.com"
            case .devnet:
                return "https://api.devnet.solana.com"
            case .testnet:
                return "https://api.testnet.solana.com"
            }
        }

        init?(clusterHint: String) {
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

    enum SendTransactionError: Error, Equatable {
        case invalidMessage
        case unsupportedMultiSignature
        case blockhashNotFound
        case invalidSendOptions
        case confirmationFailed(signature: String, message: String, code: Int?)
        case confirmationTimedOut(signature: String)
        case rpcError(message: String, code: Int?)
        case unknown
    }

    enum Commitment: String, Decodable {
        case processed
        case confirmed
        case finalized

        func satisfies(_ requestedCommitment: Commitment) -> Bool {
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

    private enum Method: String {
        case getSignatureStatuses
        case sendTransaction
    }

    private struct SendTransactionResponse: Decodable {
        let result: String?
        private let error: RPCResponseError?

        var failure: SendTransactionError? {
            guard let error else { return nil }
            if error.isBlockhashNotFound {
                return .blockhashNotFound
            }

            return error.sendTransactionFailure
        }
    }

    private struct SignatureStatusesResponse: Decodable {
        private let result: ResultValue?
        private let error: RPCResponseError?

        var status: SignatureStatus? {
            guard let values = result?.value, !values.isEmpty else { return nil }
            return values[0]
        }

        var failure: SendTransactionError? {
            guard let error else { return nil }
            return error.sendTransactionFailure
        }

        struct ResultValue: Decodable {
            let value: [SignatureStatus?]
        }
    }

    private struct SignatureStatus: Decodable {
        let err: RPCErrorValue?
        let confirmations: Int?
        let confirmationStatus: Commitment?
        private let didReturnConfirmations: Bool

        private enum CodingKeys: String, CodingKey {
            case err, confirmations, confirmationStatus
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            err = try? container.decodeIfPresent(RPCErrorValue.self, forKey: .err)
            if container.contains(.confirmations) {
                if (try? container.decodeNil(forKey: .confirmations)) == true {
                    didReturnConfirmations = true
                    confirmations = nil
                } else if let decodedConfirmations = try? container.decode(Int.self, forKey: .confirmations),
                          decodedConfirmations >= 0 {
                    didReturnConfirmations = true
                    confirmations = decodedConfirmations
                } else {
                    didReturnConfirmations = false
                    confirmations = nil
                }
            } else {
                didReturnConfirmations = false
                confirmations = nil
            }
            confirmationStatus = try? container.decodeIfPresent(Commitment.self, forKey: .confirmationStatus)
        }

        var failure: SendTransactionError? {
            guard let err else { return nil }
            return .rpcError(message: err.displayMessage ?? Strings.failedToSend,
                             code: nil)
        }

        func satisfies(_ commitment: Commitment) -> Bool {
            if let confirmationStatus {
                return confirmationStatus.satisfies(commitment)
            }

            // Older RPC nodes may omit `confirmationStatus`; a present status
            // still proves the transaction reached at least processed. Fall
            // back to legacy `confirmations` for stronger commitments.
            switch commitment {
            case .processed:
                return err == nil
            case .confirmed:
                guard didReturnConfirmations else { return false }
                return confirmations == nil || (confirmations ?? 0) > 0
            case .finalized:
                return didReturnConfirmations && confirmations == nil
            }
        }
    }

    private struct RPCResponseError: Decodable {
        let code: Int?
        let message: String?
        let data: ResponseData?
        private let rawData: RPCErrorValue?

        private enum CodingKeys: String, CodingKey {
            case code, message, data
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try? container.decodeIfPresent(Int.self, forKey: .code)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
            data = try? container.decodeIfPresent(ResponseData.self, forKey: .data)
            rawData = try? container.decodeIfPresent(RPCErrorValue.self, forKey: .data)
        }

        var displayMessage: String? {
            if let message, !message.isEmpty {
                return message
            }
            if let dataMessage = data?.message, !dataMessage.isEmpty {
                return dataMessage
            }
            return rawData?.displayMessage
        }

        var sendTransactionFailure: SendTransactionError {
            return .rpcError(message: displayMessage ?? Strings.failedToSend,
                             code: code)
        }

        var isBlockhashNotFound: Bool {
            return contains("BlockhashNotFound") ||
                contains("blockhash not found")
        }

        func contains(_ string: String) -> Bool {
            return message?.containsIgnoringCase(string) == true ||
                data?.contains(string) == true ||
                rawData?.contains(string) == true
        }

        struct ResponseData: Decodable {
            let err: RPCErrorValue?
            let message: String?

            private enum CodingKeys: String, CodingKey {
                case err, message
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                err = try? container.decodeIfPresent(RPCErrorValue.self, forKey: .err)
                message = try? container.decodeIfPresent(String.self, forKey: .message)
            }

            func contains(_ string: String) -> Bool {
                return message?.containsIgnoringCase(string) == true ||
                    err?.contains(string) == true
            }
        }
    }

    private indirect enum RPCErrorValue: Decodable {
        case string(String)
        case array([RPCErrorValue])
        case object([String: RPCErrorValue])
        case number(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([RPCErrorValue].self) {
                self = .array(value)
            } else if let value = try? container.decode([String: RPCErrorValue].self) {
                self = .object(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else {
                self = .null
            }
        }

        var displayMessage: String? {
            switch self {
            case .string(let value):
                return value.isEmpty ? nil : value
            case .array(let values):
                let messages = values.compactMap { $0.displayMessage }
                return messages.isEmpty ? nil : messages.joined(separator: ", ")
            case .object(let values):
                return values["message"]?.displayMessage ??
                    values["err"]?.displayMessage
            case .number, .bool, .null:
                return nil
            }
        }

        func contains(_ string: String) -> Bool {
            switch self {
            case .string(let value):
                return value.containsIgnoringCase(string)
            case .array(let values):
                return values.contains { $0.contains(string) }
            case .object(let values):
                return values.contains { key, value in
                    key.containsIgnoringCase(string) ||
                        value.contains(string)
                }
            case .number, .bool, .null:
                return false
            }
        }
    }

    fileprivate struct ParsedTransaction {
        let transactionData: Data
        let messageData: Data
        let messageRange: Range<Data.Index>
        let parsedMessage: SolanaWireMessage
        let signaturesStartIndex: Data.Index
    }

    fileprivate struct PreparedSignAndSendTransaction {
        let parsedTransaction: ParsedTransaction
        let signerSignatureRange: Range<Data.Index>
    }

    struct PreparedLegacySignAndSendTransaction {
        let approvalMessage: String
        fileprivate let messageData: Data
        fileprivate let parsedMessage: SolanaWireMessage
    }

    struct PreparedSerializedTransaction {
        let approvalMessage: String
        fileprivate let preparedTransaction: PreparedSignAndSendTransaction
    }

    struct PreparedSendOptions {
        let clusterHint: Cluster?
        let rpcOptions: [String: Any]
        let confirmationCommitment: Commitment?
    }

    struct RPCEndpoint {
        let url: URL
        let source: RPCSource
    }

    enum RPCSource: Equatable {
        case configured
        case publicFallback

        var displayName: String {
            switch self {
            case .configured:
                return Strings.configuredRPC
            case .publicFallback:
                return Strings.publicRPC
            }
        }
    }

    struct RPCConfiguration {
        private let infoDictionary: [String: Any]

        init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
            self.infoDictionary = infoDictionary
        }

        func endpoint(for cluster: Cluster) -> RPCEndpoint {
            if let configuredURL = configuredURL(for: cluster) {
                return RPCEndpoint(url: configuredURL, source: .configured)
            }

            return RPCEndpoint(url: URL(string: cluster.publicRPCFallbackURLString)!,
                               source: .publicFallback)
        }

        private func configuredURL(for cluster: Cluster) -> URL? {
            guard let rawValue = infoDictionary[cluster.rpcConfigurationKey] as? String else {
                return nil
            }

            let urlString = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !urlString.isEmpty,
                  let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme)
            else {
                return nil
            }

            return url
        }
    }

    static let shared = Solana()

    private let urlSession = URLSession(configuration: .default)
    private let signatureLength = 64
    private let publicKeyLength = 32
    private let signatureStatusInitialPollInterval: TimeInterval = 0.5
    private let signatureStatusMaxPollInterval: TimeInterval = 2
    private let signatureStatusPollBackoffMultiplier: TimeInterval = 1.5
    private let signatureStatusPollTimeout: TimeInterval = 45
    private static let clusterHintOptionKeys = ["bigWalletCluster", "cluster"]
    private static let allowedPreflightCommitments = Set(["processed", "confirmed", "finalized"])

    private init() {}

    static func preparedSendOptions(from rawOptions: [String: Any]?) -> Result<PreparedSendOptions, SendTransactionError> {
        let options = rawOptions ?? [:]
        switch clusterHint(from: options) {
        case .failure(let error):
            return .failure(error)
        case .success(let clusterHint):
            let parsedConfirmationCommitment: Commitment?
            switch confirmationCommitment(from: options) {
            case .failure(let error):
                return .failure(error)
            case .success(let value):
                parsedConfirmationCommitment = value
            }

            guard let rpcOptions = sanitizedRPCOptions(from: options) else {
                return .failure(.invalidSendOptions)
            }

            return .success(PreparedSendOptions(clusterHint: clusterHint,
                                                rpcOptions: rpcOptions,
                                                confirmationCommitment: parsedConfirmationCommitment))
        }
    }

    private static func clusterHint(from options: [String: Any]) -> Result<Cluster?, SendTransactionError> {
        var parsedHint: Cluster?
        for key in clusterHintOptionKeys {
            guard let value = options[key] else { continue }
            guard let rawValue = value as? String,
                  let cluster = Cluster(clusterHint: rawValue)
            else {
                return .failure(.invalidSendOptions)
            }

            if let parsedHint, parsedHint != cluster {
                return .failure(.invalidSendOptions)
            }
            parsedHint = cluster
        }

        return .success(parsedHint)
    }

    private static func confirmationCommitment(from options: [String: Any]) -> Result<Commitment?, SendTransactionError> {
        guard let value = options["commitment"] else { return .success(nil) }
        guard let rawValue = value as? String,
              let commitment = Commitment(rawValue: rawValue) else {
            return .failure(.invalidSendOptions)
        }
        return .success(commitment)
    }

    private static func sanitizedRPCOptions(from options: [String: Any]) -> [String: Any]? {
        var sanitizedOptions: [String: Any] = [
            "encoding": "base64",
            "skipPreflight": false,
        ]

        for (key, value) in options {
            switch key {
            case "encoding":
                continue
            case _ where clusterHintOptionKeys.contains(key):
                continue
            case "skipPreflight":
                guard let skipPreflight = value as? Bool, !skipPreflight else {
                    return nil
                }
            case "preflightCommitment":
                guard let commitment = value as? String,
                      allowedPreflightCommitments.contains(commitment) else {
                    return nil
                }
                sanitizedOptions[key] = commitment
            case "commitment":
                continue
            case "mode":
                guard let mode = value as? String, mode == "serial" else {
                    return nil
                }
                continue
            case "maxRetries", "minContextSlot":
                guard let intValue = nonNegativeInt(from: value) else {
                    return nil
                }
                sanitizedOptions[key] = intValue
            default:
                continue
            }
        }

        return sanitizedOptions
    }

    private static func nonNegativeInt(from value: Any) -> Int? {
        if value is Bool {
            return nil
        }

        if let intValue = value as? Int {
            return intValue >= 0 ? intValue : nil
        }

        guard let number = value as? NSNumber else {
            return nil
        }

        let doubleValue = number.doubleValue
        guard doubleValue >= 0,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue <= Double(Int.max)
        else {
            return nil
        }

        return number.intValue
    }

    func sign(message: String, asHex: Bool, privateKey: PrivateKey) -> String? {
        guard let messageData = decodeMessage(message, asHex: asHex) else { return nil }
        return sign(messageData: messageData, privateKey: privateKey)
    }

    func sign(messageData: Data, privateKey: PrivateKey) -> String? {
        return sign(digest: messageData, privateKey: privateKey)
    }

    func validationErrorForSigningTransaction(message: String, publicKey: String) -> SendTransactionError? {
        return validationError(for: preparedTransactionMessage(message: message, publicKey: publicKey))
    }

    func validationErrorForSigningTransaction(messageData: Data, publicKey: String) -> SendTransactionError? {
        return validationError(for: preparedTransactionMessage(messageData: messageData, publicKey: publicKey))
    }

    func decodeMessage(_ message: String, asHex: Bool) -> Data? {
        return asHex ? Data(hexString: message) : Base58.decodeNoCheck(string: message)
    }

    func preparedSerializedTransactionForSignAndSend(serializedTransaction: String,
                                                     publicKey: String) -> Result<PreparedSerializedTransaction, SendTransactionError> {
        return preparedSignAndSend(serializedTransaction: serializedTransaction, publicKey: publicKey).map { preparedTransaction in
            PreparedSerializedTransaction(approvalMessage: Base58.encodeNoCheck(data: preparedTransaction.parsedTransaction.messageData),
                                         preparedTransaction: preparedTransaction)
        }
    }

    func preparedLegacySignAndSendTransaction(message: String,
                                              publicKey: String) -> Result<PreparedLegacySignAndSendTransaction, SendTransactionError> {
        return preparedLegacySignAndSend(message: message, publicKey: publicKey).map { preparedTransaction in
            PreparedLegacySignAndSendTransaction(approvalMessage: message,
                                                messageData: preparedTransaction.messageData,
                                                parsedMessage: preparedTransaction.parsedMessage)
        }
    }

    func signAndSendTransaction(preparedSerializedTransaction: PreparedSerializedTransaction,
                                cluster: Cluster,
                                sendOptions: PreparedSendOptions,
                                privateKey: PrivateKey,
                                completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        switch signedTransactionForSignAndSend(preparedSerializedTransaction: preparedSerializedTransaction,
                                               privateKey: privateKey) {
        case .failure(let error):
            completion(.failure(error))
        case .success(let signedTransaction):
            sendTransaction(signed: signedTransaction, cluster: cluster, sendOptions: sendOptions, completion: completion)
        }
    }

    func signAndSendTransaction(preparedLegacyTransaction: PreparedLegacySignAndSendTransaction,
                                cluster: Cluster,
                                sendOptions: PreparedSendOptions,
                                privateKey: PrivateKey,
                                completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        guard let signedData = signatureData(digest: preparedLegacyTransaction.messageData, privateKey: privateKey),
              let raw = compileTransactionData(messageData: preparedLegacyTransaction.messageData,
                                               parsedMessage: preparedLegacyTransaction.parsedMessage,
                                               signatureData: signedData) else {
            completion(.failure(.invalidMessage))
            return
        }

        sendTransaction(signed: raw, cluster: cluster, sendOptions: sendOptions, completion: completion)
    }

    func signedTransactionForSignAndSend(preparedSerializedTransaction: PreparedSerializedTransaction,
                                         privateKey: PrivateKey) -> Result<String, SendTransactionError> {
        let prepared = preparedSerializedTransaction.preparedTransaction
        guard let signedData = signatureData(digest: prepared.parsedTransaction.messageData, privateKey: privateKey),
              let signedTransaction = compileTransactionData(transactionData: prepared.parsedTransaction.transactionData,
                                                             signerSignatureRange: prepared.signerSignatureRange,
                                                             signatureData: signedData) else {
            return .failure(.invalidMessage)
        }

        return .success(signedTransaction)
    }

    private func preparedLegacySignAndSend(message: String,
                                           publicKey: String) -> Result<(messageData: Data, parsedMessage: SolanaWireMessage), SendTransactionError> {
        switch preparedTransactionMessage(message: message, publicKey: publicKey) {
        case .failure(let error):
            return .failure(error)
        case .success(let prepared):
            let parsedMessage = prepared.parsedMessage

            // The bridge only carries message bytes for signAndSendTransaction, so
            // the wallet can safely assemble a full wire transaction only when it
            // owns the lone required signature.
            guard parsedMessage.requiredSignaturesCount == 1 else {
                return .failure(.unsupportedMultiSignature)
            }

            return .success(prepared)
        }
    }

    private func validationError<T>(for result: Result<T, SendTransactionError>) -> SendTransactionError? {
        guard case .failure(let error) = result else { return nil }
        return error
    }

    private func preparedSignAndSend(serializedTransaction: String,
                                     publicKey: String) -> Result<PreparedSignAndSendTransaction, SendTransactionError> {
        switch parsedTransaction(serializedTransaction: serializedTransaction) {
        case .failure(let error):
            return .failure(error)
        case .success(let parsedTransaction):
            guard let signerIndex = signerIndex(in: parsedTransaction.parsedMessage, for: publicKey)
            else {
                return .failure(.invalidMessage)
            }

            guard requiredCosignerSignaturesArePresent(in: parsedTransaction,
                                                       excludingSignerAt: signerIndex)
            else {
                return .failure(.unsupportedMultiSignature)
            }

            guard let signerSignatureRange = signatureRange(in: parsedTransaction,
                                                            signatureIndex: signerIndex)
            else {
                return .failure(.invalidMessage)
            }

            return .success(PreparedSignAndSendTransaction(parsedTransaction: parsedTransaction,
                                                           signerSignatureRange: signerSignatureRange))
        }
    }

    private func createRequest(method: Method, cluster: Cluster, parameters: [Any]? = nil) -> URLRequest {
        let endpoint = RPCConfiguration().endpoint(for: cluster)
        var request = URLRequest(url: endpoint.url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"

        var dict: [String: Any] = [
            "method": method.rawValue,
            "id": 1,
            "jsonrpc": "2.0",
        ]

        if let parameters {
            dict["params"] = parameters
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: dict, options: .fragmentsAllowed)
        return request
    }

    private func sendTransaction(signed: String,
                                 cluster: Cluster,
                                 sendOptions: PreparedSendOptions,
                                 completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        var parameters: [Any] = [signed]
        parameters.append(sendOptions.rpcOptions)

        performRequest(method: .sendTransaction, cluster: cluster, parameters: parameters) { (response: SendTransactionResponse?) in
            guard let response else {
                completion(.failure(.unknown))
                return
            }

            if let result = response.result {
                if let confirmationCommitment = sendOptions.confirmationCommitment {
                    self.confirmTransaction(signature: result,
                                            commitment: confirmationCommitment,
                                            cluster: cluster,
                                            deadline: Date().addingTimeInterval(self.signatureStatusPollTimeout),
                                            nextPollInterval: self.signatureStatusInitialPollInterval,
                                            lastStatusFailure: nil,
                                            completion: completion)
                } else {
                    completion(.success(result))
                }
            } else if let failure = response.failure {
                completion(.failure(failure))
            } else {
                completion(.failure(.unknown))
            }
        }
    }

    private func confirmTransaction(signature: String,
                                    commitment: Commitment,
                                    cluster: Cluster,
                                    deadline: Date,
                                    nextPollInterval: TimeInterval,
                                    lastStatusFailure: SendTransactionError?,
                                    completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        guard Date() <= deadline else {
            completion(.failure(lastStatusFailure ?? .confirmationTimedOut(signature: signature)))
            return
        }

        let parameters: [Any] = [
            [signature],
            ["searchTransactionHistory": true],
        ]
        performRequest(method: .getSignatureStatuses,
                       cluster: cluster,
                       parameters: parameters) { (response: SignatureStatusesResponse?) in
            guard let response else {
                self.scheduleConfirmationRetry(signature: signature,
                                               commitment: commitment,
                                               cluster: cluster,
                                               deadline: deadline,
                                               nextPollInterval: nextPollInterval,
                                               lastStatusFailure: lastStatusFailure,
                                               completion: completion)
                return
            }

            if let failure = response.failure {
                self.scheduleConfirmationRetry(signature: signature,
                                               commitment: commitment,
                                               cluster: cluster,
                                               deadline: deadline,
                                               nextPollInterval: nextPollInterval,
                                               lastStatusFailure: self.confirmationFailure(signature: signature,
                                                                                          failure: failure),
                                               completion: completion)
                return
            }

            guard let status = response.status else {
                self.scheduleConfirmationRetry(signature: signature,
                                               commitment: commitment,
                                               cluster: cluster,
                                               deadline: deadline,
                                               nextPollInterval: nextPollInterval,
                                               lastStatusFailure: nil,
                                               completion: completion)
                return
            }

            if let failure = status.failure {
                completion(.failure(self.confirmationFailure(signature: signature, failure: failure)))
                return
            }

            if status.satisfies(commitment) {
                completion(.success(signature))
                return
            }

            self.scheduleConfirmationRetry(signature: signature,
                                           commitment: commitment,
                                           cluster: cluster,
                                           deadline: deadline,
                                           nextPollInterval: nextPollInterval,
                                           lastStatusFailure: nil,
                                           completion: completion)
        }
    }

    private func scheduleConfirmationRetry(signature: String,
                                           commitment: Commitment,
                                           cluster: Cluster,
                                           deadline: Date,
                                           nextPollInterval: TimeInterval,
                                           lastStatusFailure: SendTransactionError?,
                                           completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        let remainingTime = deadline.timeIntervalSinceNow
        guard remainingTime > 0 else {
            completion(.failure(lastStatusFailure ?? .confirmationTimedOut(signature: signature)))
            return
        }

        let delay = min(nextPollInterval, remainingTime)
        let followingPollInterval = min(nextPollInterval * signatureStatusPollBackoffMultiplier,
                                        signatureStatusMaxPollInterval)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.confirmTransaction(signature: signature,
                                    commitment: commitment,
                                    cluster: cluster,
                                    deadline: deadline,
                                    nextPollInterval: followingPollInterval,
                                    lastStatusFailure: lastStatusFailure,
                                    completion: completion)
        }
    }

    private func confirmationFailure(signature: String, failure: SendTransactionError) -> SendTransactionError {
        switch failure {
        case .rpcError(let message, let code):
            return .confirmationFailed(signature: signature,
                                       message: message,
                                       code: code)
        case .confirmationFailed, .confirmationTimedOut:
            return failure
        case .blockhashNotFound:
            return .confirmationFailed(signature: signature,
                                       message: Strings.solanaBlockhashNotFound,
                                       code: -32003)
        case .invalidMessage, .invalidSendOptions, .unsupportedMultiSignature, .unknown:
            return .confirmationFailed(signature: signature,
                                       message: Strings.failedToSend,
                                       code: nil)
        }
    }

    private func sign(digest: Data, privateKey: PrivateKey) -> String? {
        guard let signedData = signatureData(digest: digest, privateKey: privateKey) else { return nil }
        return Base58.encodeNoCheck(data: signedData)
    }

    private func signatureData(digest: Data, privateKey: PrivateKey) -> Data? {
        return privateKey.sign(digest: digest, curve: CoinType.solana.curve)
    }

    private func compileTransactionData(messageData: Data,
                                        parsedMessage: SolanaWireMessage,
                                        signatureData: Data) -> String? {
        guard signatureData.count == signatureLength
        else { return nil }

        let placeholderSignature = Data(repeating: 0, count: signatureLength)

        var result = Data.encodeLength(parsedMessage.requiredSignaturesCount)
        result += signatureData
        for _ in 0..<max(parsedMessage.requiredSignaturesCount - 1, 0) {
            result += placeholderSignature
        }

        result += messageData
        return result.base64EncodedString()
    }

    private func compileTransactionData(transactionData: Data,
                                        signerSignatureRange: Range<Data.Index>,
                                        signatureData: Data) -> String? {
        guard signatureData.count == signatureLength
        else { return nil }

        var updatedTransaction = transactionData
        updatedTransaction.replaceSubrange(signerSignatureRange, with: signatureData)
        return updatedTransaction.base64EncodedString()
    }

    private func performRequest<Response: Decodable>(method: Method,
                                                     cluster: Cluster,
                                                     parameters: [Any]? = nil,
                                                     completion: @escaping (Response?) -> Void) {
        let request = createRequest(method: method, cluster: cluster, parameters: parameters)
        let dataTask = urlSession.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                guard let data else {
                    completion(nil)
                    return
                }

                completion(try? JSONDecoder().decode(Response.self, from: data))
            }
        }
        dataTask.resume()
    }

    private func parsedTransaction(serializedTransaction: String) -> Result<ParsedTransaction, SendTransactionError> {
        guard let transactionData = Base58.decodeNoCheck(string: serializedTransaction),
              let signaturesCount = transactionData.decodeLength(startingAt: transactionData.startIndex)
        else {
            return .failure(.invalidMessage)
        }

        guard signaturesCount.length > 0 else {
            return .failure(.invalidMessage)
        }

        let (signaturesByteLength, didOverflow) = signaturesCount.length.multipliedReportingOverflow(by: signatureLength)
        guard !didOverflow,
              let messageStartIndex = transactionData.index(signaturesCount.nextIndex,
                                                            offsetBy: signaturesByteLength,
                                                            limitedBy: transactionData.endIndex)
        else {
            return .failure(.invalidMessage)
        }

        let messageRange = messageStartIndex..<transactionData.endIndex
        let messageData = transactionData.subdata(in: messageRange)
        guard let parsedMessage = SolanaWireMessageParser.parse(messageData),
              parsedMessage.requiredSignaturesCount == signaturesCount.length
        else {
            return .failure(.invalidMessage)
        }

        return .success(ParsedTransaction(transactionData: transactionData,
                                          messageData: messageData,
                                          messageRange: messageRange,
                                          parsedMessage: parsedMessage,
                                          signaturesStartIndex: signaturesCount.nextIndex))
    }

    private func requiredCosignerSignaturesArePresent(in parsedTransaction: ParsedTransaction,
                                                      excludingSignerAt signerIndex: Int) -> Bool {
        for signatureIndex in 0..<parsedTransaction.parsedMessage.requiredSignaturesCount where signatureIndex != signerIndex {
            guard let range = signatureRange(in: parsedTransaction, signatureIndex: signatureIndex)
            else { return false }

            if parsedTransaction.transactionData[range].allSatisfy({ $0 == 0 }) {
                return false
            }
        }

        return true
    }

    private func signatureRange(in parsedTransaction: ParsedTransaction,
                                signatureIndex: Int) -> Range<Data.Index>? {
        guard signatureIndex >= 0,
              signatureIndex < parsedTransaction.parsedMessage.requiredSignaturesCount
        else {
            return nil
        }

        let (signatureOffset, didOverflow) = signatureIndex.multipliedReportingOverflow(by: signatureLength)
        guard !didOverflow,
              let signatureStart = parsedTransaction.transactionData.index(parsedTransaction.signaturesStartIndex,
                                                                           offsetBy: signatureOffset,
                                                                           limitedBy: parsedTransaction.messageRange.lowerBound),
              let signatureEnd = parsedTransaction.transactionData.index(signatureStart,
                                                                         offsetBy: signatureLength,
                                                                         limitedBy: parsedTransaction.messageRange.lowerBound)
        else {
            return nil
        }

        return signatureStart..<signatureEnd
    }

    private func preparedTransactionMessage(message: String,
                                           publicKey: String) -> Result<(messageData: Data, parsedMessage: SolanaWireMessage), SendTransactionError> {
        guard let messageData = decodeMessage(message, asHex: false) else {
            return .failure(.invalidMessage)
        }

        return preparedTransactionMessage(messageData: messageData, publicKey: publicKey)
    }

    private func preparedTransactionMessage(messageData: Data,
                                            publicKey: String) -> Result<(messageData: Data, parsedMessage: SolanaWireMessage), SendTransactionError> {
        guard let parsedMessage = SolanaWireMessageParser.parse(messageData) else {
            return .failure(.invalidMessage)
        }

        guard parsedMessage.requiredSignaturesCount > 0,
              signerIndex(in: parsedMessage, for: publicKey) != nil
        else {
            return .failure(.invalidMessage)
        }

        return .success((messageData, parsedMessage))
    }

    private func signerIndex(in parsedMessage: SolanaWireMessage, for publicKey: String) -> Int? {
        guard let publicKeyData = Base58.decodeNoCheck(string: publicKey),
              publicKeyData.count == publicKeyLength
        else {
            return nil
        }

        return parsedMessage.accountKeys
            .prefix(parsedMessage.requiredSignaturesCount)
            .firstIndex(of: publicKeyData)
    }

}

private extension String {

    func containsIgnoringCase(_ string: String) -> Bool {
        return range(of: string, options: .caseInsensitive) != nil
    }

}

extension Data {

    fileprivate func decodeLength(startingAt startIndex: Data.Index) -> (length: Int, nextIndex: Data.Index)? {
        guard startIndex < endIndex else { return nil }

        var length: UInt = 0
        var shift = 0
        var index = startIndex

        while index < endIndex {
            let element = self[index]
            index = self.index(after: index)

            guard shift < UInt.bitWidth else { return nil }
            let multiplier = UInt(1) << shift
            let (component, componentOverflow) = UInt(element & 0x7f).multipliedReportingOverflow(by: multiplier)
            guard !componentOverflow else { return nil }
            let (newLength, didOverflow) = length.addingReportingOverflow(component)
            guard !didOverflow else { return nil }
            length = newLength

            if element & 0x80 == 0 {
                guard let intLength = Int(exactly: length) else { return nil }
                return (length: intLength, nextIndex: index)
            }

            shift += 7
        }

        return nil
    }

    static func encodeLength(_ length: Int) -> Data {
        return encodeLength(UInt(length))
    }

    private static func encodeLength(_ length: UInt) -> Data {
        var remainingLength = length
        var bytes = Data()

        while true {
            var element = remainingLength & 0x7f
            remainingLength = remainingLength >> 7
            if remainingLength == 0 {
                bytes.append(UInt8(element))
                break
            } else {
                element = element | 0x80
                bytes.append(UInt8(element))
            }
        }

        return bytes
    }

}
