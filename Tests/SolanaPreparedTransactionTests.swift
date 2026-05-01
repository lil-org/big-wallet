// ∅ 2026 lil org

import XCTest
@testable import Big_Wallet

final class SolanaPreparedTransactionTests: XCTestCase {

    private let serializedTransactionSignerPublicKey = "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi"

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

}
