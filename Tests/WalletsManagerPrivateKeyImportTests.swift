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

final class WalletSigningScopeTests: XCTestCase {

    private let walletID = "approved-wallet"

    func testRequestSignerAllowsApprovedAccountAfterRejectingOtherIdentities() throws {
        let account = ethereumAccount()
        let approved = WalletAccountDescriptor(walletID: walletID, account: account)
        let backing = SigningSpy()
        let signer = requestSigner(approved: approved, backing: backing)
        let alternatives: [(String, WalletAccount)] = [
            ("other-wallet", account),
            (walletID, ethereumAccount(address: Vectors.oneEthereumAddress)),
            (walletID, ethereumAccount(path: "m/44'/60'/0'/0/1")),
            (walletID, WalletAccount(
                address: account.address,
                coin: .solana,
                derivation: account.derivation,
                derivationPath: account.derivationPath,
                publicKey: account.publicKey,
                extendedPublicKey: account.extendedPublicKey
            )),
            (walletID, ethereumAccount(
                address: Vectors.oneEthereumAddress,
                path: "m/44'/60'/0'/0/1"
            )),
        ]

        for (requestedWallet, requestedAccount) in alternatives {
            XCTAssertNil(signer.privateKey(walletID: requestedWallet, account: requestedAccount))
            XCTAssertTrue(backing.requests.isEmpty)
        }

        let key = try XCTUnwrap(signer.privateKey(walletID: walletID, account: account))
        key.withData { XCTAssertEqual($0, Vectors.sequentialPrivateKey) }
        XCTAssertEqual(backing.requests.count, 1)
        XCTAssertEqual(backing.requests.first, approved)
        XCTAssertEqual(backing.invalidations, 0)
    }

    func testRequestSignerAcceptsEthereumCaseAndIgnoresNonidentityMetadata() {
        let account = ethereumAccount()
        let approved = WalletAccountDescriptor(walletID: walletID, account: account)
        let backing = SigningSpy()
        let signer = requestSigner(approved: approved, backing: backing)
        let reconstructed = WalletAccount(
            address: account.address.uppercased(),
            coin: account.coin,
            derivation: .default,
            derivationPath: account.derivationPath,
            publicKey: "different-public-metadata",
            extendedPublicKey: "different-extended-metadata"
        )

        XCTAssertNotEqual(account, reconstructed)
        XCTAssertTrue(approved.isValid)
        XCTAssertEqual(approved.normalizedAddress, account.address.lowercased())
        XCTAssertNotNil(signer.privateKey(walletID: walletID, account: reconstructed))
        XCTAssertEqual(backing.requests, [approved])
    }

    func testRequestSignerPreservesSolanaAddressCase() {
        let account = solanaAccount(address: Vectors.sequentialSolanaAddress)
        let approved = WalletAccountDescriptor(walletID: walletID, account: account)
        let backing = SigningSpy()
        let signer = requestSigner(approved: approved, backing: backing)
        let changedCase = solanaAccount(address: account.address.replacingOccurrences(of: "C", with: "c"))

        XCTAssertNotEqual(account.address, changedCase.address)
        XCTAssertTrue(WalletAccountDescriptor(walletID: walletID, account: changedCase).isValid)
        XCTAssertNil(signer.privateKey(walletID: walletID, account: changedCase))
        XCTAssertTrue(backing.requests.isEmpty)
        XCTAssertNotNil(signer.privateKey(walletID: walletID, account: account))
        XCTAssertEqual(backing.requests, [approved])
    }

    func testInvalidScopesNeverReachRequestSignerBackingAccess() {
        for approved in invalidScopes {
            let backing = SigningSpy()
            let signer = requestSigner(approved: approved, backing: backing)

            XCTAssertFalse(approved.isValid)
            XCTAssertNil(signer.privateKey(walletID: approved.walletID, account: approved.account))
            XCTAssertTrue(backing.requests.isEmpty)
        }
    }

    func testSourceSignerRejectsAnotherStoredWalletBeforeReadingPassword() throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [
            reader.walletAttributes(id: walletID),
            reader.walletAttributes(id: "other-wallet"),
        ]
        reader.walletData = [
            walletID: Vectors.walletCoreJSONPrivateKeyFixture,
            "other-wallet": Vectors.walletCoreJSONPrivateKeyFixture,
        ]
        reader.passwordData = Vectors.walletCoreJSONPrivateKeyPassword
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        XCTAssertTrue(manager.reloadFromStore())
        let account = try XCTUnwrap(manager.wallets.first(where: { $0.id == walletID })?.accounts.first)
        let otherAccount = try XCTUnwrap(manager.wallets.first(where: { $0.id == "other-wallet" })?.accounts.first)
        let signer = SourceWalletSigner(
            approvedAccount: WalletAccountDescriptor(walletID: walletID, account: account),
            walletsManager: manager
        )

        XCTAssertNil(signer.privateKey(walletID: "other-wallet", account: otherAccount))
        XCTAssertNil(signer.privateKey(walletID: walletID, account: ethereumAccount(
            address: account.address,
            path: account.derivationPath + "/1"
        )))
        XCTAssertEqual(reader.passwordReadCount, 0)

        let reconstructed = WalletAccount(
            address: account.address.uppercased(),
            coin: account.coin,
            derivation: .custom,
            derivationPath: account.derivationPath,
            publicKey: "",
            extendedPublicKey: ""
        )
        let key = try XCTUnwrap(signer.privateKey(walletID: walletID, account: reconstructed))
        key.withData { XCTAssertEqual($0, Vectors.walletCoreJSONPrivateKeyData) }
        XCTAssertEqual(reader.passwordReadCount, 1)
    }

    func testInvalidScopesNeverReachSourceKeychain() {
        let reader = KeychainCopyMatchingStub()
        reader.passwordData = Vectors.walletCoreJSONPrivateKeyPassword
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))

        for approved in invalidScopes {
            let signer = SourceWalletSigner(approvedAccount: approved, walletsManager: manager)
            XCTAssertFalse(approved.isValid)
            XCTAssertNil(signer.privateKey(walletID: approved.walletID, account: approved.account))
        }

        XCTAssertEqual(reader.passwordReadCount, 0)
    }

    private var invalidScopes: [WalletAccountDescriptor] {
        let account = ethereumAccount()
        return [
            WalletAccountDescriptor(walletID: "", account: account),
            WalletAccountDescriptor(walletID: String(repeating: "w", count: 257), account: account),
            WalletAccountDescriptor(walletID: walletID, account: ethereumAccount(address: "0x1234")),
            WalletAccountDescriptor(walletID: walletID, account: ethereumAccount(path: "")),
            WalletAccountDescriptor(walletID: walletID, account: ethereumAccount(path: String(repeating: "m", count: 1_025))),
            WalletAccountDescriptor(
                walletID: walletID,
                coin: .ethereum,
                normalizedAddress: account.address.uppercased(),
                derivationPath: account.derivationPath
            ),
            WalletAccountDescriptor(walletID: walletID, account: solanaAccount(address: "invalid-0-address")),
        ]
    }

    private func requestSigner(
        approved: WalletAccountDescriptor,
        backing: SigningSpy
    ) -> RequestScopedWalletSigner {
        RequestScopedWalletSigner(
            backing,
            approvedAccount: approved,
            isCurrent: { true },
            acquireExecutionLease: { WalletExecutionLease {} }
        )
    }

    private func ethereumAccount(
        address: String = Vectors.sequentialEthereumAddress,
        path: String = "m/44'/60'/0'/0/0"
    ) -> WalletAccount {
        WalletAccount(
            address: address,
            coin: .ethereum,
            derivation: .custom,
            derivationPath: path,
            publicKey: Vectors.sequentialEthereumPublicKey,
            extendedPublicKey: ""
        )
    }

    private func solanaAccount(address: String) -> WalletAccount {
        WalletAccount(
            address: address,
            coin: .solana,
            derivation: .solanaSolana,
            derivationPath: "m/44'/501'/0'/0'",
            publicKey: Vectors.sequentialSolanaPublicKey,
            extendedPublicKey: ""
        )
    }

    private final class SigningSpy: OwnedWalletSigning {
        var requests = [WalletAccountDescriptor]()
        var invalidations = 0

        func privateKey(walletID: String, account: WalletAccount) -> WalletPrivateKey? {
            requests.append(WalletAccountDescriptor(walletID: walletID, account: account))
            return WalletPrivateKey(data: Vectors.sequentialPrivateKey)
        }

        func invalidate() {
            invalidations += 1
        }
    }

}
