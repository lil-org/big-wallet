import Foundation
import WalletDomain

struct SolanaSigner: Sendable {
    private static let signatureLength = 64
    private let publicKeyLength = 32
    static func preparedSendOptions(from options: [String: Any]?) -> Result<Solana.PreparedSendOptions, Solana.SendTransactionError> {
        SolanaSendOptionsParser.prepare(from: options)
    }

    func sign(message: String, asHex: Bool, privateKey: WalletPrivateKey) -> String? {
        guard let messageData = decodeMessage(message, asHex: asHex) else { return nil }
        return Self.sign(messageData: messageData, privateKey: privateKey)
    }

    static func sign(messageData: Data, privateKey: WalletPrivateKey) -> String? {
        guard let signedData = signatureData(
            digest: messageData,
            privateKey: privateKey
        ) else { return nil }
        return WalletCrypto.base58Encode(data: signedData)
    }

    static func sign(
        messageDataList: [Data],
        privateKey: WalletPrivateKey
    ) -> [String]? {
        guard let signatureDataList = privateKey.sign(digests: messageDataList, coin: .solana) else { return nil }
        return signatureDataList.map { WalletCrypto.base58Encode(data: $0) }
    }

    func validationErrorForSigningTransaction(message: String, publicKey: String) -> Solana.SendTransactionError? {
        return validationError(for: preparedTransactionMessage(message: message, publicKey: publicKey))
    }

    func preparedTransactionMessageForSigning(message: String,
                                              publicKey: String) -> Result<SolanaPreparedTransactionMessage, Solana.SendTransactionError> {
        return preparedTransactionMessage(message: message, publicKey: publicKey)
    }

    func decodeMessage(_ message: String, asHex: Bool) -> Data? {
        return asHex ? WalletCrypto.hexData(string: message) : WalletCrypto.base58Decode(string: message)
    }

    func decodeTransactionMessage(_ message: String) -> Data? {
        guard Self.isValidBase58EncodedWirePayload(message),
              let messageData = decodeMessage(message, asHex: false),
              messageData.count <= Solana.maxWirePayloadLength else { return nil }
        return messageData
    }

    func preparedSerializedTransactionForSignAndSend(serializedTransaction: String,
                                                     publicKey: String) -> Result<Solana.PreparedSerializedTransaction, Solana.SendTransactionError> {
        return preparedSignAndSend(serializedTransaction: serializedTransaction, publicKey: publicKey).map { preparedTransaction in
            Solana.PreparedSerializedTransaction(approvalMessage: WalletCrypto.base58Encode(data: preparedTransaction.parsedTransaction.messageData),
                                         preparedTransaction: preparedTransaction)
        }
    }

    func preparedLegacySignAndSendTransaction(message: String,
                                              publicKey: String) -> Result<Solana.PreparedLegacySignAndSendTransaction, Solana.SendTransactionError> {
        return preparedLegacySignAndSend(message: message, publicKey: publicKey).map { preparedTransaction in
            Solana.PreparedLegacySignAndSendTransaction(approvalMessage: message,
                                                preparedMessage: preparedTransaction)
        }
    }

    static func signedTransactionForSignAndSend(
        preparedSerializedTransaction: Solana.PreparedSerializedTransaction,
        privateKey: WalletPrivateKey
    ) -> String? {
        let prepared = preparedSerializedTransaction.preparedTransaction
        guard let signedData = signatureData(digest: prepared.parsedTransaction.messageData, privateKey: privateKey),
              let signedTransaction = compileTransactionData(transactionData: prepared.parsedTransaction.transactionData,
                                                             signerSignatureRange: prepared.signerSignatureRange,
                                                             signatureData: signedData) else {
            return nil
        }

        return signedTransaction
    }

    static func signedTransactionForSignAndSend(
        preparedLegacyTransaction: Solana.PreparedLegacySignAndSendTransaction,
        privateKey: WalletPrivateKey
    ) -> String? {
        let preparedMessage = preparedLegacyTransaction.preparedMessage
        guard let signedData = signatureData(
                  digest: preparedMessage.messageData,
                  privateKey: privateKey
              ),
              let signedTransaction = compileTransactionData(
                  messageData: preparedMessage.messageData,
                  parsedMessage: preparedMessage.parsedMessage,
                  signatureData: signedData
              ) else {
            return nil
        }
        return signedTransaction
    }

    static func transactionSignature(signedTransaction: String) -> String? {
        guard let transactionData = Data(base64Encoded: signedTransaction),
              let signaturesCount = transactionData.decodeLength(
                  startingAt: transactionData.startIndex
              ),
              signaturesCount.length > 0 else { return nil }
        let (signaturesByteCount, didOverflow) = signaturesCount.length
            .multipliedReportingOverflow(by: signatureLength)
        guard !didOverflow,
              transactionData.distance(
                  from: signaturesCount.nextIndex,
                  to: transactionData.endIndex
              ) > signaturesByteCount else { return nil }
        let signatureEnd = transactionData.index(
            signaturesCount.nextIndex,
            offsetBy: signatureLength
        )
        let signature = transactionData.subdata(
            in: signaturesCount.nextIndex..<signatureEnd
        )
        guard signature.contains(where: { $0 != 0 }) else { return nil }
        return WalletCrypto.base58Encode(data: signature)
    }

    private func preparedLegacySignAndSend(message: String,
                                           publicKey: String) -> Result<SolanaPreparedTransactionMessage, Solana.SendTransactionError> {
        switch preparedTransactionMessage(message: message, publicKey: publicKey) {
        case .failure(let error):
            return .failure(error)
        case .success(let prepared):
            let parsedMessage = prepared.parsedMessage

            guard parsedMessage.requiredSignaturesCount == 1 else {
                return .failure(.unsupportedMultiSignature)
            }

            return .success(prepared)
        }
    }

    private func validationError<T>(for result: Result<T, Solana.SendTransactionError>) -> Solana.SendTransactionError? {
        guard case .failure(let error) = result else { return nil }
        return error
    }

    private func preparedSignAndSend(serializedTransaction: String,
                                     publicKey: String) -> Result<Solana.PreparedSignAndSendTransaction, Solana.SendTransactionError> {
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

            return .success(Solana.PreparedSignAndSendTransaction(parsedTransaction: parsedTransaction,
                                                           signerSignatureRange: signerSignatureRange))
        }
    }

    private static func signatureData(digest: Data, privateKey: WalletPrivateKey) -> Data? {
        return privateKey.sign(digest: digest, coin: .solana)
    }

    private static func compileTransactionData(messageData: Data,
                                               parsedMessage: SolanaWireMessage,
                                               signatureData: Data) -> String? {
        guard signatureData.count == Self.signatureLength
        else { return nil }

        let placeholderSignature = Data(repeating: 0, count: Self.signatureLength)
        let signatureCountData = Data.encodeLength(parsedMessage.requiredSignaturesCount)
        let placeholderCount = max(parsedMessage.requiredSignaturesCount - 1, 0)

        var result = Data()
        result.reserveCapacity(signatureCountData.count + signatureData.count + placeholderCount * Self.signatureLength + messageData.count)
        result.append(signatureCountData)
        result.append(signatureData)
        for _ in 0..<placeholderCount {
            result.append(placeholderSignature)
        }

        result.append(messageData)
        return result.base64EncodedString()
    }

    private static func compileTransactionData(transactionData: Data,
                                               signerSignatureRange: Range<Data.Index>,
                                               signatureData: Data) -> String? {
        guard signatureData.count == Self.signatureLength
        else { return nil }

        var updatedTransaction = transactionData
        updatedTransaction.replaceSubrange(signerSignatureRange, with: signatureData)
        return updatedTransaction.base64EncodedString()
    }

    private func parsedTransaction(serializedTransaction: String) -> Result<Solana.ParsedTransaction, Solana.SendTransactionError> {
        guard Self.isValidBase58EncodedWirePayload(serializedTransaction) else {
            return .failure(.invalidMessage)
        }

        guard let transactionData = WalletCrypto.base58Decode(string: serializedTransaction),
              transactionData.count <= Solana.maxWirePayloadLength,
              let signaturesCount = transactionData.decodeLength(startingAt: transactionData.startIndex)
        else {
            return .failure(.invalidMessage)
        }

        guard signaturesCount.length > 0 else {
            return .failure(.invalidMessage)
        }

        let (signaturesByteLength, didOverflow) = signaturesCount.length.multipliedReportingOverflow(by: Self.signatureLength)
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

        return .success(Solana.ParsedTransaction(transactionData: transactionData,
                                          messageData: messageData,
                                          messageRange: messageRange,
                                          parsedMessage: parsedMessage,
                                          signaturesStartIndex: signaturesCount.nextIndex))
    }

    private func requiredCosignerSignaturesArePresent(in parsedTransaction: Solana.ParsedTransaction,
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

    private func signatureRange(in parsedTransaction: Solana.ParsedTransaction,
                                signatureIndex: Int) -> Range<Data.Index>? {
        guard signatureIndex >= 0,
              signatureIndex < parsedTransaction.parsedMessage.requiredSignaturesCount
        else {
            return nil
        }

        let (signatureOffset, didOverflow) = signatureIndex.multipliedReportingOverflow(by: Self.signatureLength)
        guard !didOverflow,
              let signatureStart = parsedTransaction.transactionData.index(parsedTransaction.signaturesStartIndex,
                                                                           offsetBy: signatureOffset,
                                                                           limitedBy: parsedTransaction.messageRange.lowerBound),
              let signatureEnd = parsedTransaction.transactionData.index(signatureStart,
                                                                         offsetBy: Self.signatureLength,
                                                                         limitedBy: parsedTransaction.messageRange.lowerBound)
        else {
            return nil
        }

        return signatureStart..<signatureEnd
    }

    private func preparedTransactionMessage(message: String,
                                           publicKey: String) -> Result<SolanaPreparedTransactionMessage, Solana.SendTransactionError> {
        guard let messageData = decodeTransactionMessage(message) else {
            return .failure(.invalidMessage)
        }

        return preparedTransactionMessage(messageData: messageData, publicKey: publicKey)
    }

    private func preparedTransactionMessage(messageData: Data,
                                            publicKey: String) -> Result<SolanaPreparedTransactionMessage, Solana.SendTransactionError> {
        guard let parsedMessage = SolanaWireMessageParser.parse(messageData) else {
            return .failure(.invalidMessage)
        }

        guard parsedMessage.requiredSignaturesCount > 0,
              signerIndex(in: parsedMessage, for: publicKey) != nil
        else {
            return .failure(.invalidMessage)
        }

        return .success(SolanaPreparedTransactionMessage(messageData: messageData,
                                                         parsedMessage: parsedMessage))
    }

    private func signerIndex(in parsedMessage: SolanaWireMessage, for publicKey: String) -> Int? {
        guard let publicKeyData = WalletCrypto.base58Decode(string: publicKey),
              publicKeyData.count == publicKeyLength
        else {
            return nil
        }

        return parsedMessage.accountKeys
            .prefix(parsedMessage.requiredSignaturesCount)
            .firstIndex(of: publicKeyData)
    }

    private static func isValidBase58EncodedWirePayload(_ payload: String) -> Bool {
        return payload.utf8.count <= Solana.maxBase58EncodedWirePayloadLength
    }

}

