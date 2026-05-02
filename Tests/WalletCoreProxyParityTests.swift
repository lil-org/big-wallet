// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

final class WalletCoreProxyParityTests: XCTestCase {

    private let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private let privateKeyData = Data(1...32)

    func testMnemonicAndDerivationPathFacade() {
        XCTAssertTrue(WalletCrypto.isValidMnemonic(mnemonic: mnemonic))
        XCTAssertEqual(WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 0),
                       "m/44'/60'/0'/0/0")
        XCTAssertEqual(WalletCrypto.previewDerivationIndex(derivationPath: "m/44'/501'/11'/0'", coin: .solana), 11)
    }

    func testBase58AndKeccakFacade() {
        let systemProgram = "11111111111111111111111111111111"
        XCTAssertEqual(WalletCrypto.base58Encode(data: WalletCrypto.base58Decode(string: systemProgram)!), systemProgram)
        XCTAssertEqual(WalletCrypto.hexString(data: WalletCrypto.keccak256(data: Data())),
                       "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    }

    func testHexFacadeMatchesWalletCoreHexSemantics() {
        XCTAssertEqual(WalletCrypto.hexData(string: "0x00aF"), Data([0x00, 0xaf]))
        XCTAssertEqual(WalletCrypto.hexString(data: Data([0x00, 0xaf])), "00af")
        XCTAssertNil(WalletCrypto.hexData(string: "0"))
        XCTAssertNil(WalletCrypto.hexData(string: "0xzz"))
    }

    func testPrivateKeyAndAddressFacade() throws {
        let privateKey = try testPrivateKey()

        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(data: privateKeyData, coin: .ethereum))
        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(data: privateKeyData, coin: .solana))
        XCTAssertEqual(privateKey.publicKeyData(coin: .solana).count, 32)

        let ethereumAddress = WalletCrypto.addressFromPublicKeyDescription(privateKey.publicKeyDescription(coin: .ethereum),
                                                                           coin: .ethereum)
        XCTAssertTrue(ethereumAddress.hasPrefix("0x"))
        XCTAssertEqual(ethereumAddress.count, 42)
    }

    func testExtendedPublicKeyAccountFacade() throws {
        let wallet = try testHDWallet()
        let extended = wallet.extendedPublicKey(coin: .ethereum)
        let derivationPath = WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 0)

        let account = WalletCrypto.accountFromExtendedPublicKey(extended: extended,
                                                                coin: .ethereum,
                                                                derivation: .custom,
                                                                derivationPath: derivationPath)

        XCTAssertEqual(account?.address, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        XCTAssertEqual(account?.publicKey.isEmpty, false)
        XCTAssertEqual(account?.extendedPublicKey, extended)
    }

    #if DEBUG
    func testStoredKeySkipsUnsupportedCoinAccounts() throws {
        let password = Data("password".utf8)
        guard let key = WalletStoredKey.importHDWallet(mnemonic: mnemonic,
                                                       name: "test",
                                                       password: password,
                                                       coin: .ethereum) else {
            XCTFail("Expected valid stored key")
            return
        }

        key.addUnsupportedAccountForTesting()
        let wallet = WalletContainer(id: "test", key: key)

        XCTAssertEqual(key.accountCount, 2)
        XCTAssertEqual(wallet.accounts.count, 1)
        XCTAssertEqual(wallet.accounts.first?.coin, .ethereum)

        guard let replacement = WalletStoredKey.importHDWallet(mnemonic: mnemonic,
                                                               name: "replacement",
                                                               password: password,
                                                               coin: .ethereum) else {
            XCTFail("Expected valid replacement key")
            return
        }

        replacement.removeAccountForCoin(coin: .ethereum)
        replacement.copyUnsupportedAccounts(from: key)
        let replacementWallet = WalletContainer(id: "replacement", key: replacement)

        XCTAssertEqual(replacement.accountCount, 1)
        XCTAssertTrue(replacementWallet.accounts.isEmpty)
    }
    #endif

    func testEthereumSigningFacade() throws {
        let privateKey = try testPrivateKey()
        let digest = Data(repeating: 1, count: 32)

        let signature = privateKey.sign(digest: digest, coin: .ethereum)
        XCTAssertEqual(signature?.count, 65)

        let signedTransaction = WalletCrypto.signEthereumTransaction(chainID: Data([1]),
                                                                     nonce: Data(),
                                                                     gasPrice: Data([1]),
                                                                     gasLimit: Data([0x52, 0x08]),
                                                                     toAddress: "0x0000000000000000000000000000000000000001",
                                                                     privateKey: privateKey,
                                                                     amount: Data(),
                                                                     data: Data())
        XCTAssertFalse(signedTransaction.isEmpty)
    }

    func testTypedDataFacadeReturnsDigest() {
        let typedData = """
        {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"Mail":[{"name":"contents","type":"string"}]},"primaryType":"Mail","domain":{"name":"Big Wallet","version":"1","chainId":1,"verifyingContract":"0x0000000000000000000000000000000000000000"},"message":{"contents":"hello"}}
        """

        XCTAssertEqual(WalletCrypto.ethereumTypedDataDigest(messageJson: typedData).count, 32)
    }

    private func testPrivateKey(file: StaticString = #filePath, line: UInt = #line) throws -> WalletPrivateKey {
        guard let privateKey = WalletPrivateKey(data: privateKeyData) else {
            XCTFail("Expected valid private key", file: file, line: line)
            throw WalletKeyStoreError.invalidKey
        }
        return privateKey
    }

    private func testHDWallet(file: StaticString = #filePath, line: UInt = #line) throws -> WalletHDWallet {
        guard let wallet = WalletHDWallet(mnemonic: mnemonic, passphrase: "") else {
            XCTFail("Expected test mnemonic to create HD wallet", file: file, line: line)
            throw WalletKeyStoreError.invalidMnemonic
        }
        return wallet
    }

}
