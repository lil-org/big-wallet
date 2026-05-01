// ∅ 2026 lil org

import Foundation
import WalletCore
import XCTest
@testable import Big_Wallet

final class WalletsManagerPrivateKeyImportTests: XCTestCase {

    private enum TestError: Error {
        case invalidPrivateKey
    }

    private let privateKeyData = Data(1...32)

    func testSolanaPrivateKeyExportUsesPhantomSecretKeyFormat() throws {
        let privateKey = try testPrivateKey()

        let exported = WalletsManager.privateKeyExportString(privateKey: privateKey, coin: .solana)
        guard let decoded = Base58.decodeNoCheck(string: exported) else {
            XCTFail("Expected Solana private key export to be base58")
            return
        }

        XCTAssertEqual(decoded.count, 64)
        XCTAssertEqual(Data(decoded.prefix(32)), privateKeyData)
        XCTAssertEqual(Data(decoded.suffix(32)), privateKey.getPublicKey(coinType: .solana).data)
        XCTAssertNotEqual(exported, privateKeyData.hexString)
    }

    func testSolanaPrivateKeyImportAcceptsPhantomSecretKeyFormat() throws {
        let privateKey = try testPrivateKey()

        let exported = WalletsManager.privateKeyExportString(privateKey: privateKey, coin: .solana)
        let imported = WalletsManager.privateKeyImport(from: exported)

        XCTAssertEqual(imported?.coin, .solana)
        XCTAssertEqual(imported?.privateKey.data, privateKeyData)
    }

    func testSolanaPrivateKeyImportAcceptsBase58SeedFormat() {
        let exported = Base58.encodeNoCheck(data: privateKeyData)
        let imported = WalletsManager.privateKeyImport(from: exported)

        XCTAssertEqual(imported?.coin, .solana)
        XCTAssertEqual(imported?.privateKey.data, privateKeyData)
    }

    func testSolanaPrivateKeyImportAcceptsByteArraySecretKeyFormat() throws {
        let privateKey = try testPrivateKey()

        var secretKey = privateKey.data
        secretKey.append(privateKey.getPublicKey(coinType: .solana).data)
        let byteArrayString = "[" + secretKey.map(String.init).joined(separator: ",") + "]"
        let imported = WalletsManager.privateKeyImport(from: byteArrayString)

        XCTAssertEqual(imported?.coin, .solana)
        XCTAssertEqual(imported?.privateKey.data, privateKeyData)
    }

    func testSolanaPrivateKeyImportRejectsByteArraySecretKeyWithInvalidLength() {
        let secretKey = Data(1...33)
        let byteArrayString = "[" + secretKey.map(String.init).joined(separator: ",") + "]"

        XCTAssertNil(WalletsManager.privateKeyImport(from: byteArrayString))
    }

    func testSolanaPrivateKeyImportRejectsMismatchedPublicKey() throws {
        let privateKey = try testPrivateKey()

        var secretKey = privateKey.data
        secretKey.append(Data(repeating: 9, count: 32))
        let exported = Base58.encodeNoCheck(data: secretKey)

        XCTAssertNil(WalletsManager.privateKeyImport(from: exported))
    }

    func testEthereumPrivateKeyExportStaysHex() throws {
        let privateKey = try testPrivateKey()

        let exported = WalletsManager.privateKeyExportString(privateKey: privateKey, coin: .ethereum)

        XCTAssertEqual(exported, privateKeyData.hexString)
    }

    func testEthereumPrivateKeyImportStaysHex() {
        let privateKeyData = Data(1...32)
        let imported = WalletsManager.privateKeyImport(from: privateKeyData.hexString)

        XCTAssertEqual(imported?.coin, .ethereum)
        XCTAssertEqual(imported?.privateKey.data, privateKeyData)
    }

    private func testPrivateKey(file: StaticString = #filePath, line: UInt = #line) throws -> PrivateKey {
        guard let privateKey = PrivateKey(data: privateKeyData) else {
            XCTFail("Expected valid private key", file: file, line: line)
            throw TestError.invalidPrivateKey
        }
        return privateKey
    }

}
