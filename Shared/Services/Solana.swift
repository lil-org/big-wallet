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
        if firstByte & 0x80 == 0 {
            return Prefix(requiredSignaturesCount: Int(firstByte), accountCountOffset: 3)
        } else {
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

    enum SendTransactionError: Error, Equatable {
        case invalidMessage
        case unsupportedMultiSignature
        case unsupportedClusterSelection
        case blockhashNotFound
        case unknown
    }

    private enum Method: String {
        case sendTransaction
        case getLatestBlockhash
    }

    private struct SendTransactionResponse: Codable {
        let result: String?
        private let error: ResponseError?

        var blockhashNotFound: Bool {
            return error?.data.err == "BlockhashNotFound"
        }

        private struct ResponseError: Codable {
            let data: ResponseData

            struct ResponseData: Codable {
                let err: String
            }
        }
    }

    private struct LatestBlockhashResponse: Codable {
        let result: Result

        struct Result: Codable {
            let value: Value

            struct Value: Codable {
                let blockhash: String
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

    static let shared = Solana()

    private let urlSession = URLSession(configuration: .default)
    private let maxSendTransactionRetryCount = 3

    // Temporary fallback until cluster selection is threaded through the
    // request contract.
    private let rpcURL = URL(string: "https://api.mainnet-beta.solana.com")
    private let signatureLength = 64
    private let publicKeyLength = 32

    private init() {}

    var supportsTransactionSending: Bool {
        return rpcURL != nil
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
                                options: [String: Any]?,
                                privateKey: PrivateKey,
                                completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        switch signedTransactionForSignAndSend(preparedSerializedTransaction: preparedSerializedTransaction,
                                               privateKey: privateKey) {
        case .failure(let error):
            completion(.failure(error))
        case .success(let signedTransaction):
            // Serialized transactions may already include co-signer signatures.
            sendTransaction(signed: signedTransaction, options: options, completion: completion)
        }
    }

    func signAndSendTransaction(preparedLegacyTransaction: PreparedLegacySignAndSendTransaction,
                                options: [String: Any]?,
                                privateKey: PrivateKey,
                                completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        signAndSendTransaction(retryCount: 0,
                               preparedLegacyTransaction: preparedLegacyTransaction,
                               options: options,
                               privateKey: privateKey,
                               completion: completion)
    }

    private func signAndSendTransaction(retryCount: Int,
                                        preparedLegacyTransaction: PreparedLegacySignAndSendTransaction,
                                        options: [String: Any]?,
                                        privateKey: PrivateKey,
                                        completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        guard retryCount < maxSendTransactionRetryCount else {
            completion(.failure(.unknown))
            return
        }

        guard let signed = sign(digest: preparedLegacyTransaction.messageData, privateKey: privateKey),
              let raw = compileTransactionData(messageData: preparedLegacyTransaction.messageData,
                                               parsedMessage: preparedLegacyTransaction.parsedMessage,
                                               signature: signed) else {
            completion(.failure(.invalidMessage))
            return
        }

        sendTransaction(signed: raw, options: options) { [weak self] result in
            switch result {
            case .success:
                completion(result)
            case .failure(.blockhashNotFound):
                self?.updatedPreparedLegacyTransactionBlockhash(preparedLegacyTransaction) { updatedTransaction in
                    guard let self, let updatedTransaction else {
                        completion(.failure(.unknown))
                        return
                    }

                    self.signAndSendTransaction(retryCount: retryCount + 1,
                                                preparedLegacyTransaction: updatedTransaction,
                                                options: options,
                                                privateKey: privateKey,
                                                completion: completion)
                }
            case .failure:
                completion(result)
            }
        }
    }

    func signedTransactionForSignAndSend(preparedSerializedTransaction: PreparedSerializedTransaction,
                                         privateKey: PrivateKey) -> Result<String, SendTransactionError> {
        let prepared = preparedSerializedTransaction.preparedTransaction
        guard let signed = sign(digest: prepared.parsedTransaction.messageData, privateKey: privateKey),
              let signedTransaction = compileTransactionData(transactionData: prepared.parsedTransaction.transactionData,
                                                             signerSignatureRange: prepared.signerSignatureRange,
                                                             signature: signed) else {
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

            let (signerSignatureOffset, didOverflow) = signerIndex.multipliedReportingOverflow(by: signatureLength)
            guard !didOverflow,
                  let signerSignatureStart = parsedTransaction.transactionData.index(parsedTransaction.signaturesStartIndex,
                                                                                    offsetBy: signerSignatureOffset,
                                                                                    limitedBy: parsedTransaction.messageRange.lowerBound),
                  let signerSignatureEnd = parsedTransaction.transactionData.index(signerSignatureStart,
                                                                                  offsetBy: signatureLength,
                                                                                  limitedBy: parsedTransaction.messageRange.lowerBound)
            else {
                return .failure(.invalidMessage)
            }

            return .success(PreparedSignAndSendTransaction(parsedTransaction: parsedTransaction,
                                                           signerSignatureRange: signerSignatureStart..<signerSignatureEnd))
        }
    }

    private func createRequest(method: Method, parameters: [Any]? = nil) -> URLRequest? {
        guard let rpcURL else { return nil }
        var request = URLRequest(url: rpcURL)
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

    private func getLatestBlockhash(completion: @escaping (String?) -> Void) {
        performRequest(method: .getLatestBlockhash) { (response: LatestBlockhashResponse?) in
            completion(response?.result.value.blockhash)
        }
    }

    private func updatedPreparedLegacyTransactionBlockhash(_ preparedLegacyTransaction: PreparedLegacySignAndSendTransaction,
                                                           completion: @escaping (PreparedLegacySignAndSendTransaction?) -> Void) {
        updatedMessageDataWithLatestBlockhash(messageData: preparedLegacyTransaction.messageData,
                                              parsedMessage: preparedLegacyTransaction.parsedMessage) { updatedMessageData in
            guard let updatedMessageData else {
                completion(nil)
                return
            }

            completion(PreparedLegacySignAndSendTransaction(approvalMessage: Base58.encodeNoCheck(data: updatedMessageData),
                                                            messageData: updatedMessageData,
                                                            parsedMessage: preparedLegacyTransaction.parsedMessage))
        }
    }

    private func updatedMessageDataWithLatestBlockhash(messageData: Data,
                                                       parsedMessage: SolanaWireMessage,
                                                       completion: @escaping (Data?) -> Void) {
        getLatestBlockhash { blockhash in
            guard let blockhash,
                  let blockhashData = Base58.decodeNoCheck(string: blockhash),
                  blockhashData.count == parsedMessage.blockhashRange.count
            else {
                completion(nil)
                return
            }

            var updatedMessageData = messageData
            updatedMessageData.replaceSubrange(parsedMessage.blockhashRange, with: blockhashData)
            completion(updatedMessageData)
        }
    }

    private func sendTransaction(signed: String,
                                 options: [String: Any]?,
                                 completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        guard supportsTransactionSending else {
            completion(.failure(.unsupportedClusterSelection))
            return
        }
        var parameters: [Any] = [signed]
        if let options {
            parameters.append(options)
        }

        performRequest(method: .sendTransaction, parameters: parameters) { (response: SendTransactionResponse?) in
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
        guard let signed = privateKey.sign(digest: digest, curve: CoinType.solana.curve) else { return nil }
        return Base58.encodeNoCheck(data: signed)
    }

    private func compileTransactionData(messageData: Data,
                                        parsedMessage: SolanaWireMessage,
                                        signature: String) -> String? {
        guard let signatureData = Base58.decodeNoCheck(string: signature)
        else { return nil }

        let placeholderSignature = Data(repeating: 0, count: 64)

        var result = Data.encodeLength(parsedMessage.requiredSignaturesCount)
        result += signatureData
        for _ in 0..<max(parsedMessage.requiredSignaturesCount - 1, 0) {
            result += placeholderSignature
        }

        result += messageData
        return Base58.encodeNoCheck(data: result)
    }

    private func compileTransactionData(transactionData: Data,
                                        signerSignatureRange: Range<Data.Index>,
                                        signature: String) -> String? {
        guard let signatureData = Base58.decodeNoCheck(string: signature),
              signatureData.count == signatureLength
        else { return nil }

        var updatedTransaction = transactionData
        updatedTransaction.replaceSubrange(signerSignatureRange, with: signatureData)
        return Base58.encodeNoCheck(data: updatedTransaction)
    }

    private func performRequest<Response: Decodable>(method: Method,
                                                     parameters: [Any]? = nil,
                                                     completion: @escaping (Response?) -> Void) {
        guard let request = createRequest(method: method, parameters: parameters) else {
            completion(nil)
            return
        }
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
