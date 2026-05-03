// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

private typealias Vectors = WalletCoreProxyTestVectors

final class WalletsManagerPrivateKeyImportTests: XCTestCase {

    private enum TestError: Error {
        case invalidPrivateKey
    }

    private let privateKeyData = Data(1...32)

    func testSolanaPrivateKeyExportUsesPhantomSecretKeyFormat() throws {
        let privateKey = try testPrivateKey()

        let exported = WalletsManager.privateKeyExportString(privateKey: privateKey, coin: .solana)
        guard let decoded = WalletCrypto.base58Decode(string: exported) else {
            XCTFail("Expected Solana private key export to be base58")
            return
        }

        XCTAssertEqual(decoded.count, 64)
        XCTAssertEqual(Data(decoded.prefix(32)), privateKeyData)
        XCTAssertEqual(Data(decoded.suffix(32)), privateKey.publicKeyData(coin: .solana))
        XCTAssertEqual(exported, Vectors.solanaSequentialSecretKeyBase58)
        XCTAssertNotEqual(exported, WalletCrypto.hexString(data: privateKeyData))
    }

    func testSolanaPrivateKeyImportAcceptsPhantomSecretKeyFormat() {
        let imported = WalletsManager.privateKeyImport(from: Vectors.solanaSequentialSecretKeyBase58)

        XCTAssertEqual(imported?.coin, .solana)
        assertPrivateKey(imported?.privateKey, equals: privateKeyData)
    }

    func testSolanaPrivateKeyImportAcceptsBase58SeedFormat() {
        let imported = WalletsManager.privateKeyImport(from: Vectors.solanaSequentialSeedBase58)

        XCTAssertEqual(imported?.coin, .solana)
        assertPrivateKey(imported?.privateKey, equals: privateKeyData)
    }

    func testSolanaPrivateKeyImportAcceptsByteArraySecretKeyFormat() {
        let imported = WalletsManager.privateKeyImport(from: Vectors.solanaSequentialSecretKeyByteArray)

        XCTAssertEqual(imported?.coin, .solana)
        assertPrivateKey(imported?.privateKey, equals: privateKeyData)
    }

    func testSolanaPrivateKeyImportAcceptsByteArraySeedAndWhitespaceSecretKeyFormats() {
        let seedByteArray = "[ " + privateKeyData.map(String.init).joined(separator: " , ") + " ]"
        let secretKeyWithWhitespace = Vectors.solanaSequentialSecretKeyByteArray
            .replacingOccurrences(of: ",", with: ", ")

        let importedSeed = WalletsManager.privateKeyImport(from: seedByteArray)
        let importedSecretKey = WalletsManager.privateKeyImport(from: secretKeyWithWhitespace)

        XCTAssertEqual(importedSeed?.coin, .solana)
        XCTAssertEqual(importedSecretKey?.coin, .solana)
        assertPrivateKey(importedSeed?.privateKey, equals: privateKeyData)
        assertPrivateKey(importedSecretKey?.privateKey, equals: privateKeyData)
    }

    func testSolanaPrivateKeyImportRejectsByteArraySecretKeyWithInvalidLength() {
        let secretKey = Data(1...33)
        let byteArrayString = "[" + secretKey.map(String.init).joined(separator: ",") + "]"

        XCTAssertNil(WalletsManager.privateKeyImport(from: byteArrayString))
    }

    func testSolanaPrivateKeyImportRejectsInvalidByteArrayValues() {
        let thirtyOneOnes = Array(repeating: "1", count: 31)
        let invalidInputs = [
            byteArrayString(["true"] + thirtyOneOnes),
            byteArrayString(["1.5"] + thirtyOneOnes),
            byteArrayString(["-1"] + thirtyOneOnes),
            byteArrayString(["256"] + thirtyOneOnes),
            byteArrayString(["\"1\""] + thirtyOneOnes),
            byteArrayString(["1"]),
            byteArrayString(Array(repeating: "1", count: 65)),
            byteArrayString(Array(repeating: "1", count: 31) + ["[]"]),
            "{}",
            "[[]]",
            "[1,]",
            "[1,2",
        ]

        for input in invalidInputs {
            XCTAssertNil(WalletsManager.privateKeyImport(from: input), "Expected invalid byte array to be rejected: \(input)")
        }
    }

    func testSolanaPrivateKeyImportRejectsMismatchedPublicKey() throws {
        let privateKey = try testPrivateKey()

        let exported = privateKey.withData { privateKeyData in
            var secretKey = privateKeyData
            defer { secretKey.resetBytes(in: 0..<secretKey.count) }
            secretKey.append(Data(repeating: 9, count: 32))
            return WalletCrypto.base58Encode(data: secretKey)
        }

        XCTAssertNil(WalletsManager.privateKeyImport(from: exported))
    }

    func testSolanaPrivateKeyImportRejectsByteArraySecretKeyWithMismatchedPublicKey() {
        var mismatchedSecretKey = privateKeyData
        mismatchedSecretKey.append(Data(repeating: 7, count: 32))
        let byteArrayString = "[" + mismatchedSecretKey.map(String.init).joined(separator: ",") + "]"

        XCTAssertNil(WalletsManager.privateKeyImport(from: byteArrayString))
    }

    func testSolanaPrivateKeyImportRejectsBadBase58Seeds() {
        let invalidAlphabetSeed = String(repeating: "1", count: 31) + "0"

        XCTAssertNil(WalletsManager.privateKeyImport(from: "11111111111111111111111111111111"))
        XCTAssertEqual(invalidAlphabetSeed.count, 32)
        XCTAssertNil(WalletCrypto.base58Decode(string: invalidAlphabetSeed))
        XCTAssertNil(WalletsManager.privateKeyImport(from: invalidAlphabetSeed))
    }

    func testEthereumPrivateKeyExportStaysHex() throws {
        let privateKey = try testPrivateKey()

        let exported = WalletsManager.privateKeyExportString(privateKey: privateKey, coin: .ethereum)

        XCTAssertEqual(exported, WalletCrypto.hexString(data: privateKeyData))
    }

    func testEthereumPrivateKeyImportStaysHex() {
        let privateKeyData = Data(1...32)
        let imported = WalletsManager.privateKeyImport(from: WalletCrypto.hexString(data: privateKeyData))

        XCTAssertEqual(imported?.coin, .ethereum)
        assertPrivateKey(imported?.privateKey, equals: privateKeyData)
    }

    func testEthereumPrivateKeyImportRejectsInvalidHexKeys() {
        XCTAssertNil(WalletsManager.privateKeyImport(from: WalletCrypto.hexString(data: Vectors.zeroPrivateKey)))
        XCTAssertNil(WalletsManager.privateKeyImport(from: WalletCrypto.hexString(data: Data(repeating: 1, count: 31))))
        XCTAssertNil(WalletsManager.privateKeyImport(from: WalletCrypto.hexString(data: Data(repeating: 1, count: 33))))
        XCTAssertNil(WalletsManager.privateKeyImport(from: WalletCrypto.hexString(data: Vectors.secp256k1PrivateKeyAtCurveOrder)))
        XCTAssertNil(WalletsManager.privateKeyImport(from: WalletCrypto.hexString(data: Vectors.secp256k1PrivateKeyAboveCurveOrder)))
        XCTAssertNil(WalletsManager.privateKeyImport(from: "0X" + WalletCrypto.hexString(data: privateKeyData)))
    }

    func testEthereumPrivateKeyImportAcceptsBase58DecodableHexThatIsInvalidForSolana() throws {
        let input = Vectors.ethereumHexThatDecodesAsInvalidSolanaSecretBase58
        let decodedAsBase58 = try XCTUnwrap(WalletCrypto.base58Decode(string: input))
        let imported = WalletsManager.privateKeyImport(from: input)

        XCTAssertEqual(decodedAsBase58.count, 64)
        XCTAssertEqual(Data(decodedAsBase58.prefix(32)), Vectors.zeroPrivateKey)
        XCTAssertEqual(imported?.coin, .ethereum)
        assertPrivateKey(imported?.privateKey, equals: Vectors.data(hex: input))
    }

    private func testPrivateKey(file: StaticString = #filePath, line: UInt = #line) throws -> WalletPrivateKey {
        guard let privateKey = WalletPrivateKey(data: privateKeyData) else {
            XCTFail("Expected valid private key", file: file, line: line)
            throw TestError.invalidPrivateKey
        }
        return privateKey
    }

    private func assertPrivateKey(_ privateKey: WalletPrivateKey?,
                                  equals expectedData: Data,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        guard let privateKey else {
            XCTFail("Expected valid private key", file: file, line: line)
            return
        }

        privateKey.withData {
            XCTAssertEqual($0, expectedData, file: file, line: line)
        }
    }

    private func byteArrayString(_ values: [String]) -> String {
        return "[" + values.joined(separator: ",") + "]"
    }

}
