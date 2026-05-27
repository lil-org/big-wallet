// ∅ 2026 lil org

import XCTest
import CryptoKit
@testable import Big_Wallet

private typealias Vectors = WalletCoreProxyTestVectors

private func assertValidSolanaSignature(_ signature: Data,
                                        message: Data,
                                        publicKeyData: Data,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) throws {
    XCTAssertEqual(signature.count, 64, file: file, line: line)
    XCTAssertEqual(publicKeyData.count, 32, file: file, line: line)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    XCTAssertTrue(publicKey.isValidSignature(signature, for: message), file: file, line: line)
}

private func assertValidSolanaSignature(_ signatureBase58: String?,
                                        message: Data,
                                        publicKeyHex: String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) throws {
    let signatureBase58 = try XCTUnwrap(signatureBase58, file: file, line: line)
    let signature = try XCTUnwrap(WalletCrypto.base58Decode(string: signatureBase58), file: file, line: line)
    let publicKeyData = try XCTUnwrap(WalletCrypto.hexData(string: publicKeyHex), file: file, line: line)
    try assertValidSolanaSignature(signature, message: message, publicKeyData: publicKeyData, file: file, line: line)
}

final class SolanaPreparedTransactionTests: XCTestCase {

    private let serializedTransactionSignerPublicKey = "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi"

    func testSolanaMessageSigningWrappersProduceValidSignatures() throws {
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Vectors.solanaSigningPrivateKey))

        try assertValidSolanaSignature(Solana.shared.sign(messageData: Vectors.solanaMessage, privateKey: privateKey),
                                       message: Vectors.solanaMessage,
                                       publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(Solana.shared.sign(message: Vectors.solanaMessageBase58,
                                                          asHex: false,
                                                          privateKey: privateKey),
                                       message: Vectors.solanaMessage,
                                       publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(Solana.shared.sign(message: Vectors.solanaMessageHex,
                                                          asHex: true,
                                                          privateKey: privateKey),
                                       message: Vectors.solanaMessage,
                                       publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(Solana.shared.sign(messageData: Data(), privateKey: privateKey),
                                       message: Data(),
                                       publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(Solana.shared.sign(message: "", asHex: true, privateKey: privateKey),
                                       message: Data(),
                                       publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(Solana.shared.sign(messageData: Data(repeating: 0, count: 32), privateKey: privateKey),
                                       message: Data(repeating: 0, count: 32),
                                       publicKeyHex: Vectors.solanaSigningPublicKey)

        XCTAssertNil(Solana.shared.sign(message: "", asHex: false, privateKey: privateKey))
        XCTAssertNil(Solana.shared.sign(message: "0OIl", asHex: false, privateKey: privateKey))
        XCTAssertNil(Solana.shared.sign(message: "abc", asHex: true, privateKey: privateKey))
        XCTAssertNil(Solana.shared.sign(message: "0X00", asHex: true, privateKey: privateKey))
    }

    func testSerializedSolanaSignAndSendRejectsMissingCosignerSignature() {
        let publicKey = serializedTransactionSignerPublicKey
        let serializedTransaction = "6t24vfGqc3gdHL1msMPmHDkE7aRCWD9nwgMFGiSsLMEkN3z3fK6hCk41Y9kYxHKYM4SfgppbThLWmvfrjdSwfB2eRFgvxsb26BrJZFGYm8EHNbjnzRQ3m2pjkiXd5xTBdgFFNviEF8hrVsLS9cqtGd3ktVSthWL1wbj4nkCVPGjkkCcTay1bWoVCLEZvzcLFbn1BDCMYMAhThjbQKYGpDR1TVEB6x4VR8Ha6umVUxGDQXMRcVrHdGZKT8xtf7YWn5JNNZGE3aeTMGBE75PdC3BsX8TfJbgzomc1DZnceVKN2WtWgarT3uXCf47jRCYrHj5WVAMBRagqYMBYV5Aw74iTkmUbTA1vpU1BScs7ozyW7"

        switch Solana.shared.preparedSerializedTransactionForSignAndSend(serializedTransaction: serializedTransaction,
                                                                         publicKey: publicKey) {
        case .failure(.unsupportedMultiSignature):
            break
        case .failure(let error):
            XCTFail("Expected unsupportedMultiSignature, got \(error)")
        case .success:
            XCTFail("Expected missing cosigner signature to be rejected")
        }
    }

    func testSerializedSolanaSignAndSendAcceptsPresentCosignerSignature() {
        let publicKey = serializedTransactionSignerPublicKey
        let serializedTransaction = "6t24vfGqc3gdHL1msMPmHDkE7aRCWD9nwgMFGiSsLMEkN3z3fK6hCk41Y9kYxHKYM4SfgppbThLWmvfrjdSwfB2eRPFZ3pbJhMNrBA2Gzbg3GUEMMvEPu3aukDxNtYzVDC8jNnyhAvC41eDA5aFCXdxba7TDo8qxrw7AmHXyPTVymxmJinebHHcukjJK8GHcqGJaknfeBUQyspxamAFcw8MqKtNNR18bBbqyzNrwr2MmA3bkbV9Vyko39uuVn3iz1vWXRVmoS8v4t5qXXFiMiKHyfuTwdpS5pHA7p9TeNFrqgC2TatFggbDWNogbGnV8gN52qc9Mjgs7S7ZDoWhPzhb4cPRH9Mj2RemE5ay7SmUj"

        switch Solana.shared.preparedSerializedTransactionForSignAndSend(serializedTransaction: serializedTransaction,
                                                                         publicKey: publicKey) {
        case .success:
            break
        case .failure(let error):
            XCTFail("Expected prepared transaction, got \(error)")
        }
    }

    func testSerializedSolanaSignAndSendProducesValidSignedTransaction() throws {
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey))

        switch Solana.shared.preparedSerializedTransactionForSignAndSend(serializedTransaction: Vectors.solanaPreparedSerializedTransaction,
                                                                         publicKey: Vectors.solanaPreparedSignerPublicKey) {
        case .success(let preparedTransaction):
            XCTAssertEqual(preparedTransaction.approvalMessage, Vectors.solanaPreparedApprovalMessage)
            XCTAssertEqual(WalletCrypto.base58Encode(data: preparedTransaction.messageData), Vectors.solanaPreparedApprovalMessage)

            switch Solana.shared.signedTransactionForSignAndSend(preparedSerializedTransaction: preparedTransaction,
                                                                 privateKey: privateKey) {
            case .success(let signedTransaction):
                let signedData = try XCTUnwrap(Data(base64Encoded: signedTransaction))
                let signedParts = try signerSignature(in: signedData, signerPublicKey: Vectors.solanaPreparedSignerPublicKey)

                XCTAssertEqual(signedParts.messageData, preparedTransaction.messageData)
                try assertValidSolanaSignature(signedParts.signature,
                                               message: signedParts.messageData,
                                               publicKeyData: signedParts.publicKeyData)
            case .failure(let error):
                XCTFail("Expected signed transaction, got \(error)")
            }
        case .failure(let error):
            XCTFail("Expected prepared transaction, got \(error)")
        }
    }

    private func signerSignature(in transactionData: Data,
                                 signerPublicKey: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws -> (signature: Data, messageData: Data, publicKeyData: Data) {
        let publicKeyData = try XCTUnwrap(WalletCrypto.base58Decode(string: signerPublicKey), file: file, line: line)
        let signaturesCount = try XCTUnwrap(Self.decodeCompactLength(transactionData, startingAt: transactionData.startIndex),
                                            file: file,
                                            line: line)
        let signaturesByteLength = signaturesCount.length * 64
        let messageStart = try XCTUnwrap(transactionData.index(signaturesCount.nextIndex,
                                                               offsetBy: signaturesByteLength,
                                                               limitedBy: transactionData.endIndex),
                                         file: file,
                                         line: line)
        let messageData = transactionData.subdata(in: messageStart..<transactionData.endIndex)
        let parsedMessage = try XCTUnwrap(SolanaWireMessageParser.parse(messageData), file: file, line: line)
        let signerIndex = try XCTUnwrap(parsedMessage.accountKeys.prefix(parsedMessage.requiredSignaturesCount).firstIndex(of: publicKeyData),
                                        file: file,
                                        line: line)

        let boundedSignerIndex = try XCTUnwrap(signerIndex < signaturesCount.length ? signerIndex : nil,
                                               file: file,
                                               line: line)
        let signatureStart = try XCTUnwrap(transactionData.index(signaturesCount.nextIndex,
                                                                 offsetBy: boundedSignerIndex * 64,
                                                                 limitedBy: transactionData.endIndex),
                                           file: file,
                                           line: line)
        let signatureEnd = try XCTUnwrap(transactionData.index(signatureStart, offsetBy: 64, limitedBy: transactionData.endIndex),
                                         file: file,
                                         line: line)

        return (transactionData.subdata(in: signatureStart..<signatureEnd), messageData, publicKeyData)
    }

    private static func decodeCompactLength(_ data: Data, startingAt startIndex: Data.Index) -> (length: Int, nextIndex: Data.Index)? {
        guard startIndex < data.endIndex else { return nil }

        var length: UInt = 0
        var shift = 0
        var index = startIndex

        while index < data.endIndex {
            let element = data[index]
            index = data.index(after: index)

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

}
