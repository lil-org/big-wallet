// ∅ 2026 lil org

import XCTest
@testable import Big_Wallet

private typealias Vectors = WalletCoreProxyTestVectors

final class SolanaPreparedTransactionTests: XCTestCase {

    private let serializedTransactionSignerPublicKey = "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi"

    func testSolanaMessageSigningWrappersMatchProxyVectors() throws {
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Vectors.solanaSigningPrivateKey))

        XCTAssertEqual(Solana.shared.sign(messageData: Vectors.solanaMessage, privateKey: privateKey),
                       Vectors.solanaMessageSignature)
        XCTAssertEqual(Solana.shared.sign(message: Vectors.solanaMessageBase58, asHex: false, privateKey: privateKey),
                       Vectors.solanaMessageSignature)
        XCTAssertEqual(Solana.shared.sign(message: Vectors.solanaMessageHex, asHex: true, privateKey: privateKey),
                       Vectors.solanaMessageSignature)
        XCTAssertEqual(Solana.shared.sign(messageData: Data(), privateKey: privateKey),
                       Vectors.solanaEmptyMessageSignature)
        XCTAssertEqual(Solana.shared.sign(message: "", asHex: true, privateKey: privateKey),
                       Vectors.solanaEmptyMessageSignature)
        XCTAssertEqual(Solana.shared.sign(messageData: Data(repeating: 0, count: 32), privateKey: privateKey),
                       Vectors.solanaZeroMessageSignature)

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

    func testSerializedSolanaSignAndSendProducesDeterministicSignedTransaction() throws {
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey))

        switch Solana.shared.preparedSerializedTransactionForSignAndSend(serializedTransaction: Vectors.solanaPreparedSerializedTransaction,
                                                                         publicKey: Vectors.solanaPreparedSignerPublicKey) {
        case .success(let preparedTransaction):
            XCTAssertEqual(preparedTransaction.approvalMessage, Vectors.solanaPreparedApprovalMessage)
            XCTAssertEqual(WalletCrypto.base58Encode(data: preparedTransaction.messageData), Vectors.solanaPreparedApprovalMessage)

            switch Solana.shared.signedTransactionForSignAndSend(preparedSerializedTransaction: preparedTransaction,
                                                                 privateKey: privateKey) {
            case .success(let signedTransaction):
                XCTAssertEqual(signedTransaction, Vectors.solanaPreparedSignedTransactionBase64)
            case .failure(let error):
                XCTFail("Expected signed transaction, got \(error)")
            }
        case .failure(let error):
            XCTFail("Expected prepared transaction, got \(error)")
        }
    }

}
