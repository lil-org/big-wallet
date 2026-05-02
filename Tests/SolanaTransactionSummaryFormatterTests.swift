// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

final class SolanaTransactionSummaryFormatterTests: XCTestCase {

    func testSolanaSummaryDecodesSystemTransfer() {
        let payer = Data(repeating: 7, count: 32)
        let recipient = Data(repeating: 8, count: 32)
        let message = SolanaMessageFixture.wireMessage(readOnlyUnsignedAccounts: 1,
                                        accountKeys: [
                                            payer,
                                            recipient,
                                            WalletCrypto.base58Decode(string: "11111111111111111111111111111111")!,
                                        ],
                                        bodyAfterBlockhash: SolanaMessageFixture.instruction(programIdIndex: 2,
                                                                        accountIndices: [0, 1],
                                                                        data: SolanaMessageFixture.uint32LE(2) + SolanaMessageFixture.uint64LE(5_000)))

        let approval = SolanaTransactionSummaryFormatter.approvalMessage(messageData: message,
                                                                         encodedMessages: ["encoded"])

        XCTAssertTrue(approval.contains("Transfer 0.000005 SOL"))
        XCTAssertTrue(approval.contains("From: \(WalletCrypto.base58Encode(data: payer)) - signer - writable"))
        XCTAssertTrue(approval.contains("To: \(WalletCrypto.base58Encode(data: recipient)) - writable"))
        XCTAssertTrue(approval.contains("Data:\n\nencoded"))
    }

    func testSolanaSummaryDecodesTokenTransferChecked() {
        let authority = Data(repeating: 1, count: 32)
        let source = Data(repeating: 2, count: 32)
        let destination = Data(repeating: 3, count: 32)
        let mint = Data(repeating: 4, count: 32)
        let message = SolanaMessageFixture.wireMessage(requiredSignatures: 1,
                                        readOnlyUnsignedAccounts: 2,
                                        accountKeys: [
                                            authority,
                                            source,
                                            destination,
                                            mint,
                                            WalletCrypto.base58Decode(string: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")!,
                                        ],
                                        bodyAfterBlockhash: SolanaMessageFixture.instruction(programIdIndex: 4,
                                                                        accountIndices: [1, 3, 2, 0],
                                                                        data: Data([12]) + SolanaMessageFixture.uint64LE(1_250_000) + Data([6])))

        let approval = SolanaTransactionSummaryFormatter.approvalMessage(messageData: message,
                                                                         encodedMessages: ["encoded"])

        XCTAssertTrue(approval.contains("SPL Token transfer 1.25"))
        XCTAssertTrue(approval.contains("Mint: \(WalletCrypto.base58Encode(data: mint))"))
        XCTAssertTrue(approval.contains("Authority: \(WalletCrypto.base58Encode(data: authority)) - signer - writable"))
    }

    func testSolanaSummaryIncludesTokenMultisigSignerAccounts() {
        let firstSigner = Data(repeating: 1, count: 32)
        let secondSigner = Data(repeating: 2, count: 32)
        let source = Data(repeating: 3, count: 32)
        let destination = Data(repeating: 4, count: 32)
        let mint = Data(repeating: 5, count: 32)
        let multisigAuthority = Data(repeating: 6, count: 32)
        let trailingAccount = Data(repeating: 7, count: 32)
        let message = SolanaMessageFixture.wireMessage(requiredSignatures: 2,
                                        readOnlySignedAccounts: 1,
                                        readOnlyUnsignedAccounts: 4,
                                        accountKeys: [
                                            firstSigner,
                                            secondSigner,
                                            source,
                                            destination,
                                            mint,
                                            multisigAuthority,
                                            trailingAccount,
                                            WalletCrypto.base58Decode(string: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")!,
                                        ],
                                        bodyAfterBlockhash: SolanaMessageFixture.instruction(programIdIndex: 7,
                                                                        accountIndices: [2, 4, 3, 5, 0, 1, 6],
                                                                        data: Data([12]) + SolanaMessageFixture.uint64LE(1_250_000) + Data([6])))

        let approval = SolanaTransactionSummaryFormatter.approvalMessage(messageData: message,
                                                                         encodedMessages: ["encoded"])

        XCTAssertTrue(approval.contains("Authority: \(WalletCrypto.base58Encode(data: multisigAuthority))"))
        XCTAssertTrue(approval.contains("Additional signer 1: \(WalletCrypto.base58Encode(data: firstSigner)) - signer - writable"))
        XCTAssertTrue(approval.contains("Additional signer 2: \(WalletCrypto.base58Encode(data: secondSigner)) - signer"))
        XCTAssertTrue(approval.contains("Additional account 3: \(WalletCrypto.base58Encode(data: trailingAccount))"))
    }

    func testSolanaSummaryLabelsUncheckedTokenAmountsAsRaw() {
        let authority = Data(repeating: 1, count: 32)
        let source = Data(repeating: 2, count: 32)
        let destination = Data(repeating: 3, count: 32)
        let message = SolanaMessageFixture.wireMessage(requiredSignatures: 1,
                                        readOnlyUnsignedAccounts: 1,
                                        accountKeys: [
                                            authority,
                                            source,
                                            destination,
                                            WalletCrypto.base58Decode(string: "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb")!,
                                        ],
                                        bodyAfterBlockhash: SolanaMessageFixture.instruction(programIdIndex: 3,
                                                                        accountIndices: [1, 2, 0],
                                                                        data: Data([3]) + SolanaMessageFixture.uint64LE(1_250_000)))

        let approval = SolanaTransactionSummaryFormatter.approvalMessage(messageData: message,
                                                                         encodedMessages: ["encoded"])

        XCTAssertTrue(approval.contains("Token-2022 transfer raw amount 1250000"))
        XCTAssertTrue(approval.contains("Token amount is raw base units because this instruction does not include decimals."))
        XCTAssertTrue(approval.contains("Token-2022 accounts or mints may use extensions that are not fully reflected in this summary."))
    }

    func testSolanaSummaryFormatsMultipleDecodedMessages() {
        let payer = Data(repeating: 7, count: 32)
        let firstRecipient = Data(repeating: 8, count: 32)
        let secondRecipient = Data(repeating: 9, count: 32)
        let systemProgram = WalletCrypto.base58Decode(string: "11111111111111111111111111111111")!
        let firstMessage = SolanaMessageFixture.wireMessage(readOnlyUnsignedAccounts: 1,
                                             accountKeys: [payer, firstRecipient, systemProgram],
                                             bodyAfterBlockhash: SolanaMessageFixture.instruction(programIdIndex: 2,
                                                                             accountIndices: [0, 1],
                                                                             data: SolanaMessageFixture.uint32LE(2) + SolanaMessageFixture.uint64LE(5_000)))
        let secondMessage = SolanaMessageFixture.wireMessage(readOnlyUnsignedAccounts: 1,
                                              accountKeys: [payer, secondRecipient, systemProgram],
                                              bodyAfterBlockhash: SolanaMessageFixture.instruction(programIdIndex: 2,
                                                                              accountIndices: [0, 1],
                                                                              data: SolanaMessageFixture.uint32LE(2) + SolanaMessageFixture.uint64LE(10_000)))

        let approval = SolanaTransactionSummaryFormatter.approvalMessage(encodedMessages: ["encoded-one", "encoded-two"],
                                                                         messageDataList: [firstMessage, secondMessage])

        XCTAssertTrue(approval.contains("Transaction 1"))
        XCTAssertTrue(approval.contains("Transfer 0.000005 SOL"))
        XCTAssertTrue(approval.contains("Data:\n\nencoded-one"))
        XCTAssertTrue(approval.contains("Transaction 2"))
        XCTAssertTrue(approval.contains("Transfer 0.00001 SOL"))
        XCTAssertTrue(approval.contains("Data:\n\nencoded-two"))
    }

    func testSolanaSummaryFormatsEmptyMessageListAsRawWarning() {
        let approval = SolanaTransactionSummaryFormatter.approvalMessage(encodedMessages: [],
                                                                         messageDataList: [])

        XCTAssertFalse(approval.isEmpty)
        XCTAssertTrue(approval.contains("Data:\n\n"))
    }

    func testSolanaSummaryDecodesAtaComputeBudgetMemoAndUnknownFallback() {
        let payer = Data(repeating: 1, count: 32)
        let associatedTokenAccount = Data(repeating: 2, count: 32)
        let owner = Data(repeating: 3, count: 32)
        let mint = Data(repeating: 4, count: 32)
        let unknownProgram = Data(repeating: 5, count: 32)
        let accountKeys = [
            payer,
            associatedTokenAccount,
            owner,
            mint,
            WalletCrypto.base58Decode(string: "11111111111111111111111111111111")!,
            WalletCrypto.base58Decode(string: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")!,
            WalletCrypto.base58Decode(string: "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")!,
            WalletCrypto.base58Decode(string: "ComputeBudget111111111111111111111111111111")!,
            WalletCrypto.base58Decode(string: "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr")!,
            unknownProgram,
        ]
        var bodyAfterBlockhash = Data.encodeLength(4)
        bodyAfterBlockhash += SolanaMessageFixture.compiledInstruction(programIdIndex: 6,
                                                  accountIndices: [0, 1, 2, 3, 4, 5],
                                                  data: Data([1]))
        bodyAfterBlockhash += SolanaMessageFixture.compiledInstruction(programIdIndex: 7,
                                                  accountIndices: [],
                                                  data: Data([2]) + SolanaMessageFixture.uint32LE(200_000))
        bodyAfterBlockhash += SolanaMessageFixture.compiledInstruction(programIdIndex: 8,
                                                  accountIndices: [],
                                                  data: Data("hello\nRisk notes".utf8))
        bodyAfterBlockhash += SolanaMessageFixture.compiledInstruction(programIdIndex: 9,
                                                  accountIndices: [0, 1],
                                                  data: Data([0xde, 0xad, 0xbe, 0xef]))

        let message = SolanaMessageFixture.wireMessage(readOnlyUnsignedAccounts: 6,
                                        accountKeys: accountKeys,
                                        bodyAfterBlockhash: bodyAfterBlockhash)
        let approval = SolanaTransactionSummaryFormatter.approvalMessage(messageData: message,
                                                                         encodedMessages: ["encoded"])

        XCTAssertTrue(approval.contains("Create associated token account if needed"))
        XCTAssertTrue(approval.contains("Set compute unit limit"))
        XCTAssertTrue(approval.contains("Text: hello\\nRisk notes"))
        XCTAssertFalse(approval.contains("Text: hello\nRisk notes"))
        XCTAssertTrue(approval.contains("Unknown program instruction"))
        XCTAssertTrue(approval.contains("1 instruction could not be decoded."))
    }

    func testSolanaApprovalTextSanitizerEscapesVisualLineBreaksAndFormatControls() {
        let text = "safe\u{2028}line\u{202e}a\u{200b}bc"
        let sanitized = SolanaApprovalTextSanitizer.inline(text)

        XCTAssertEqual(sanitized, "safe\\nlineabc")
    }

    func testSolanaApprovalTextSanitizerOnlyAddsEllipsisWhenTruncated() {
        XCTAssertEqual(SolanaApprovalTextSanitizer.inline("abcde", maxLength: 5), "abcde")
        XCTAssertEqual(SolanaApprovalTextSanitizer.inline("abcdef", maxLength: 5), "ab...")
        XCTAssertEqual(SolanaApprovalTextSanitizer.inline("ab\nc", maxLength: 5), "ab\\nc")
        XCTAssertEqual(SolanaApprovalTextSanitizer.inline("ab\ncd", maxLength: 5), "ab...")
    }

    func testSolanaSummaryDecodesTaggedAssociatedTokenCreate() {
        let payer = Data(repeating: 1, count: 32)
        let associatedTokenAccount = Data(repeating: 2, count: 32)
        let owner = Data(repeating: 3, count: 32)
        let mint = Data(repeating: 4, count: 32)
        let message = SolanaMessageFixture.wireMessage(readOnlyUnsignedAccounts: 3,
                                        accountKeys: [
                                            payer,
                                            associatedTokenAccount,
                                            owner,
                                            mint,
                                            WalletCrypto.base58Decode(string: "11111111111111111111111111111111")!,
                                            WalletCrypto.base58Decode(string: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")!,
                                            WalletCrypto.base58Decode(string: "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")!,
                                        ],
                                        bodyAfterBlockhash: SolanaMessageFixture.instruction(programIdIndex: 6,
                                                                        accountIndices: [0, 1, 2, 3, 4, 5],
                                                                        data: Data([0])))

        let approval = SolanaTransactionSummaryFormatter.approvalMessage(messageData: message,
                                                                         encodedMessages: ["encoded"])

        XCTAssertTrue(approval.contains("Create associated token account"))
        XCTAssertFalse(approval.contains("Unknown program instruction"))
    }

    func testSolanaSummaryDecodesRecoverNestedAtaAccountRoles() {
        let wallet = Data(repeating: 1, count: 32)
        let nestedAssociatedTokenAccount = Data(repeating: 2, count: 32)
        let destinationAssociatedTokenAccount = Data(repeating: 3, count: 32)
        let ownerAssociatedTokenAccount = Data(repeating: 4, count: 32)
        let nestedTokenMint = Data(repeating: 5, count: 32)
        let ownerTokenMint = Data(repeating: 6, count: 32)
        let tokenProgram = WalletCrypto.base58Decode(string: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")!
        let associatedTokenProgram = WalletCrypto.base58Decode(string: "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")!
        let message = SolanaMessageFixture.wireMessage(requiredSignatures: 1,
                                        readOnlyUnsignedAccounts: 4,
                                        accountKeys: [
                                            wallet,
                                            nestedAssociatedTokenAccount,
                                            destinationAssociatedTokenAccount,
                                            ownerAssociatedTokenAccount,
                                            nestedTokenMint,
                                            ownerTokenMint,
                                            tokenProgram,
                                            associatedTokenProgram,
                                        ],
                                        bodyAfterBlockhash: SolanaMessageFixture.instruction(programIdIndex: 7,
                                                                        accountIndices: [1, 4, 2, 3, 5, 0, 6],
                                                                        data: Data([2])))

        let approval = SolanaTransactionSummaryFormatter.approvalMessage(messageData: message,
                                                                         encodedMessages: ["encoded"])

        XCTAssertTrue(approval.contains("Recover nested associated token account"))
        XCTAssertTrue(approval.contains("Nested associated token account: \(WalletCrypto.base58Encode(data: nestedAssociatedTokenAccount)) - writable"))
        XCTAssertTrue(approval.contains("Nested token mint: \(WalletCrypto.base58Encode(data: nestedTokenMint))"))
        XCTAssertTrue(approval.contains("Destination associated token account: \(WalletCrypto.base58Encode(data: destinationAssociatedTokenAccount)) - writable"))
        XCTAssertTrue(approval.contains("Owner associated token account: \(WalletCrypto.base58Encode(data: ownerAssociatedTokenAccount)) - writable"))
        XCTAssertTrue(approval.contains("Owner token mint: \(WalletCrypto.base58Encode(data: ownerTokenMint))"))
        XCTAssertTrue(approval.contains("Wallet: \(WalletCrypto.base58Encode(data: wallet)) - signer - writable"))
        XCTAssertFalse(approval.contains("Payer:"))
    }

}
