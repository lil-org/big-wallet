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

    private struct Prefix {
        let requiredSignaturesCount: Int
        let accountCountOffset: Int
    }

    static func parse(_ messageData: Data) -> SolanaWireMessage? {
        guard let prefix = prefix(for: messageData),
              let accountCountIndex = messageData.index(messageData.startIndex, offsetBy: prefix.accountCountOffset, limitedBy: messageData.endIndex),
              let decodedLength = messageData.decodeLength(startingAt: accountCountIndex)
        else { return nil }

        guard decodedLength.length >= prefix.requiredSignaturesCount else { return nil }

        let (accountKeysLength, didOverflow) = decodedLength.length.multipliedReportingOverflow(by: publicKeyLength)
        guard !didOverflow,
              let accountKeysEndIndex = messageData.index(decodedLength.nextIndex, offsetBy: accountKeysLength, limitedBy: messageData.endIndex),
              let blockhashEndIndex = messageData.index(accountKeysEndIndex, offsetBy: blockhashLength, limitedBy: messageData.endIndex)
        else { return nil }

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
            return Prefix(requiredSignaturesCount: Int(firstByte), accountCountOffset: 3)
        } else {
            guard firstByte & versionMask == supportedVersionedMessageVersion else { return nil }

            guard let signaturesCountIndex = messageData.index(messageData.startIndex, offsetBy: 1, limitedBy: messageData.endIndex),
                  signaturesCountIndex < messageData.endIndex
            else {
                return nil
            }
            return Prefix(requiredSignaturesCount: Int(messageData[signaturesCountIndex]), accountCountOffset: 4)
        }
    }
}

final class Solana {

    enum Cluster: String, CaseIterable {
        case mainnetBeta
        case devnet

        var displayName: String {
            switch self {
            case .mainnetBeta:
                return "Mainnet"
            case .devnet:
                return "Devnet"
            }
        }

        fileprivate var rpcConfigurationKey: String {
            switch self {
            case .mainnetBeta:
                return "SolanaMainnetRPCURL"
            case .devnet:
                return "SolanaDevnetRPCURL"
            }
        }

        fileprivate var publicRPCFallbackURLString: String {
            switch self {
            case .mainnetBeta:
                return "https://api.mainnet.solana.com"
            case .devnet:
                return "https://api.devnet.solana.com"
            }
        }

        init?(clusterHint: String) {
            switch clusterHint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "mainnet", "mainnet-beta", "mainnetbeta", "solana:mainnet":
                self = .mainnetBeta
            case "devnet", "solana:devnet":
                self = .devnet
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
        case unknown
    }

    private enum Method: String {
        case sendTransaction
    }

    private struct SendTransactionResponse: Codable {
        let result: String?
        private let error: ResponseError?

        var blockhashNotFound: Bool {
            return error?.data?.err == "BlockhashNotFound"
        }

        private struct ResponseError: Codable {
            let data: ResponseData?

            struct ResponseData: Codable {
                let err: String?
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
    private static let clusterHintOptionKeys = ["bigWalletCluster", "cluster"]
    private static let allowedPreflightCommitments = Set(["processed", "confirmed", "finalized"])

    private init() {}

    static func preparedSendOptions(from rawOptions: [String: Any]?) -> Result<PreparedSendOptions, SendTransactionError> {
        let options = rawOptions ?? [:]
        switch clusterHint(from: options) {
        case .failure(let error):
            return .failure(error)
        case .success(let clusterHint):
            guard let rpcOptions = sanitizedRPCOptions(from: options) else {
                return .failure(.invalidSendOptions)
            }

            return .success(PreparedSendOptions(clusterHint: clusterHint,
                                                rpcOptions: rpcOptions))
        }
    }

    private static func clusterHint(from options: [String: Any]) -> Result<Cluster?, SendTransactionError> {
        var parsedHints = [Cluster]()
        for key in clusterHintOptionKeys {
            guard let value = options[key] else { continue }
            guard let rawValue = value as? String,
                  let cluster = Cluster(clusterHint: rawValue)
            else {
                return .failure(.invalidSendOptions)
            }

            parsedHints.append(cluster)
        }

        guard Set(parsedHints).count <= 1 else {
            return .failure(.invalidSendOptions)
        }

        return .success(parsedHints.first)
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
                                options: [String: Any],
                                privateKey: PrivateKey,
                                completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        switch signedTransactionForSignAndSend(preparedSerializedTransaction: preparedSerializedTransaction,
                                               privateKey: privateKey) {
        case .failure(let error):
            completion(.failure(error))
        case .success(let signedTransaction):
            sendTransaction(signed: signedTransaction, cluster: cluster, options: options, completion: completion)
        }
    }

    func signAndSendTransaction(preparedLegacyTransaction: PreparedLegacySignAndSendTransaction,
                                cluster: Cluster,
                                options: [String: Any],
                                privateKey: PrivateKey,
                                completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        guard let signedData = signatureData(digest: preparedLegacyTransaction.messageData, privateKey: privateKey),
              let raw = compileTransactionData(messageData: preparedLegacyTransaction.messageData,
                                               parsedMessage: preparedLegacyTransaction.parsedMessage,
                                               signatureData: signedData) else {
            completion(.failure(.invalidMessage))
            return
        }

        sendTransaction(signed: raw, cluster: cluster, options: options, completion: completion)
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
                                 options: [String: Any],
                                 completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        var parameters: [Any] = [signed]
        parameters.append(options)

        performRequest(method: .sendTransaction, cluster: cluster, parameters: parameters) { (response: SendTransactionResponse?) in
            guard let response else {
                completion(.failure(.unknown))
                return
            }

            if let result = response.result {
                completion(.success(result))
            } else if response.blockhashNotFound {
                completion(.failure(.blockhashNotFound))
            } else {
                completion(.failure(.unknown))
            }
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
