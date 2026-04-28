// ∅ 2026 lil org

import XCTest
import WalletCore
@testable import Big_Wallet

final class Tests_iOS: XCTestCase {

    func testGM() {
        XCTAssert("gm" == "gm")
    }

    func testSolanaPrivateKeyExportUsesPhantomSecretKeyFormat() {
        let privateKeyData = Data(1...32)
        guard let privateKey = PrivateKey(data: privateKeyData) else {
            XCTFail("Expected valid private key")
            return
        }

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

    func testEthereumPrivateKeyExportStaysHex() {
        let privateKeyData = Data(1...32)
        guard let privateKey = PrivateKey(data: privateKeyData) else {
            XCTFail("Expected valid private key")
            return
        }

        let exported = WalletsManager.privateKeyExportString(privateKey: privateKey, coin: .ethereum)

        XCTAssertEqual(exported, privateKeyData.hexString)
    }
    
}
