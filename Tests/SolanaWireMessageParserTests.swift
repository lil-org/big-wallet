// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

final class SolanaWireMessageParserTests: XCTestCase {

    func testSolanaParserAcceptsVersionZeroMessages() {
        let message = SolanaMessageFixture.wireMessage(version: 0,
                                        accountKeySeeds: [7],
                                        bodyAfterBlockhash: [0, 0])

        guard let parsedMessage = SolanaWireMessageParser.parse(message) else {
            XCTFail("Expected Solana v0 message to parse")
            return
        }

        XCTAssertEqual(parsedMessage.requiredSignaturesCount, 1)
        XCTAssertEqual(parsedMessage.accountKeys.count, 1)
        XCTAssertEqual(parsedMessage.blockhashRange.lowerBound, 37)
        XCTAssertEqual(parsedMessage.blockhashRange.upperBound, 69)
    }

    func testSolanaParserAcceptsLegacyMessagesWithInstructions() {
        let message = SolanaMessageFixture.wireMessage(readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: [1, 1, 1, 0, 0])

        guard let parsedMessage = SolanaWireMessageParser.parse(message) else {
            XCTFail("Expected complete legacy message to parse")
            return
        }

        XCTAssertEqual(parsedMessage.requiredSignaturesCount, 1)
        XCTAssertEqual(parsedMessage.accountKeys.count, 2)
        XCTAssertEqual(parsedMessage.blockhashRange.lowerBound, 68)
        XCTAssertEqual(parsedMessage.blockhashRange.upperBound, 100)
        XCTAssertEqual(parsedMessage.instructions, [
            SolanaCompiledInstruction(programIdIndex: 1, accountIndices: [0], data: Data()),
        ])
        XCTAssertTrue(parsedMessage.isSigner(accountIndex: 0))
        XCTAssertTrue(parsedMessage.isWritable(accountIndex: 0))
        XCTAssertFalse(parsedMessage.isWritable(accountIndex: 1))
    }

    func testSolanaParserReturnsAddressLookupMetadata() {
        var bodyAfterBlockhash = Data([1, 1, 1, 2, 0])
        bodyAfterBlockhash.append(1)
        bodyAfterBlockhash.append(Data(repeating: 10, count: 32))
        bodyAfterBlockhash.append(contentsOf: [1, 5, 1, 6])

        let message = SolanaMessageFixture.wireMessage(version: 0,
                                        readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: bodyAfterBlockhash)

        guard let parsedMessage = SolanaWireMessageParser.parse(message) else {
            XCTFail("Expected complete v0 message with lookup addresses to parse")
            return
        }

        XCTAssertEqual(parsedMessage.version, .version0)
        XCTAssertEqual(parsedMessage.addressTableLookups, [
            SolanaAddressTableLookup(accountKey: Data(repeating: 10, count: 32),
                                     writableIndexes: [5],
                                     readOnlyIndexes: [6]),
        ])
        XCTAssertEqual(parsedMessage.totalReferencedAccountCount, 4)
        XCTAssertTrue(parsedMessage.isWritable(accountIndex: 2))
        XCTAssertFalse(parsedMessage.isWritable(accountIndex: 3))
    }

    func testSolanaParserAcceptsVersionZeroMessagesWithAddressLookups() {
        var bodyAfterBlockhash = Data([1, 1, 1, 2, 0])
        bodyAfterBlockhash.append(1)
        bodyAfterBlockhash.append(Data(repeating: 10, count: 32))
        bodyAfterBlockhash.append(contentsOf: [1, 5, 0])

        let message = SolanaMessageFixture.wireMessage(version: 0,
                                        readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: bodyAfterBlockhash)

        guard let parsedMessage = SolanaWireMessageParser.parse(message) else {
            XCTFail("Expected complete v0 message with lookup addresses to parse")
            return
        }

        XCTAssertEqual(parsedMessage.requiredSignaturesCount, 1)
        XCTAssertEqual(parsedMessage.accountKeys.count, 2)
        XCTAssertEqual(parsedMessage.blockhashRange.lowerBound, 69)
        XCTAssertEqual(parsedMessage.blockhashRange.upperBound, 101)
    }

    func testSolanaParserRejectsIncompleteVersionZeroMessages() {
        let message = SolanaMessageFixture.wireMessage(version: 0,
                                        accountKeySeeds: [7],
                                        bodyAfterBlockhash: [])

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsTruncatedLegacyInstructionData() {
        let message = SolanaMessageFixture.wireMessage(readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: [1, 1, 1, 0, 1])

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsHugeMalformedInstructionCount() {
        let message = SolanaMessageFixture.wireMessage(accountKeySeeds: [7],
                                        bodyAfterBlockhash: Data.encodeLength(Int.max))

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsHugeMalformedAddressLookupCount() {
        var bodyAfterBlockhash = Data([0])
        bodyAfterBlockhash.append(Data.encodeLength(Int.max))
        let message = SolanaMessageFixture.wireMessage(version: 0,
                                        accountKeySeeds: [7],
                                        bodyAfterBlockhash: bodyAfterBlockhash)

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsReadOnlyFeePayer() {
        let message = SolanaMessageFixture.wireMessage(readOnlySignedAccounts: 1,
                                        accountKeySeeds: [7],
                                        bodyAfterBlockhash: [0])

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsTrailingBytesAfterLegacyInstructions() {
        let message = SolanaMessageFixture.wireMessage(accountKeySeeds: [7],
                                        bodyAfterBlockhash: [0, 0])

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsLegacyInstructionIndexOutsideAccountKeys() {
        let message = SolanaMessageFixture.wireMessage(accountKeySeeds: [7],
                                        bodyAfterBlockhash: [1, 1, 0, 0])

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsInstructionProgramIndexAtFeePayer() {
        let message = SolanaMessageFixture.wireMessage(readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: [1, 0, 0, 0])

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsVersionZeroProgramIndexFromAddressLookup() {
        var bodyAfterBlockhash = Data([1, 2, 0, 0])
        bodyAfterBlockhash.append(1)
        bodyAfterBlockhash.append(Data(repeating: 10, count: 32))
        bodyAfterBlockhash.append(contentsOf: [1, 5, 0])

        let message = SolanaMessageFixture.wireMessage(version: 0,
                                        readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: bodyAfterBlockhash)

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsVersionZeroAccountIndexOutsideReferencedAccounts() {
        var bodyAfterBlockhash = Data([1, 1, 1, 3, 0])
        bodyAfterBlockhash.append(1)
        bodyAfterBlockhash.append(Data(repeating: 10, count: 32))
        bodyAfterBlockhash.append(contentsOf: [1, 5, 0])

        let message = SolanaMessageFixture.wireMessage(version: 0,
                                        readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: bodyAfterBlockhash)

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsEmptyAddressLookupTableEntries() {
        var bodyAfterBlockhash = Data([0, 1])
        bodyAfterBlockhash.append(Data(repeating: 10, count: 32))
        bodyAfterBlockhash.append(contentsOf: [0, 0])

        let message = SolanaMessageFixture.wireMessage(version: 0,
                                        accountKeySeeds: [7],
                                        bodyAfterBlockhash: bodyAfterBlockhash)

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsTooManyReferencedAccounts() {
        var bodyAfterBlockhash = Data([0, 1])
        bodyAfterBlockhash.append(Data(repeating: 10, count: 32))
        bodyAfterBlockhash.append(Data.encodeLength(Int(UInt8.max)))
        bodyAfterBlockhash.append(Data((0..<Int(UInt8.max)).map { UInt8($0) }))
        bodyAfterBlockhash.append(0)

        let message = SolanaMessageFixture.wireMessage(version: 0,
                                        readOnlyUnsignedAccounts: 1,
                                        accountKeySeeds: [7, 8],
                                        bodyAfterBlockhash: bodyAfterBlockhash)

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

    func testSolanaParserRejectsOversizedMessages() {
        let oversizedMessage = Data(repeating: 0, count: 1_233)

        XCTAssertNil(SolanaWireMessageParser.parse(oversizedMessage))
    }

    func testSolanaParserRejectsUnsupportedVersionedMessages() {
        let message = SolanaMessageFixture.wireMessage(version: 1,
                                        accountKeySeeds: [7],
                                        bodyAfterBlockhash: [])

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

}
