// ∅ 2026 lil org

import Foundation
import Security
import XCTest
@testable import Big_Wallet

private typealias Vectors = WalletCoreProxyTestVectors

final class WalletsManagerPreviewTests: XCTestCase {

    private enum PreviewTestError: Error {
        case failed
    }

    private let mnemonic = Vectors.abandonMnemonic

    func testEthereumPreviewReturnsPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: .ethereum)

        XCTAssertEqual(accounts.count, 11)
        XCTAssertTrue(accounts.allSatisfy { $0.coin == .ethereum })
        XCTAssertTrue(accounts.allSatisfy { !$0.address.isEmpty })
        XCTAssertTrue(accounts.allSatisfy { $0.extendedPublicKey == Vectors.abandonEthereumExtendedPublicKey })

        for accountIndex in 0...10 {
            let vector = try XCTUnwrap(Vectors.abandonEthereumHDVectors.first { $0.index == accountIndex })
            assertPreviewAccount(accounts[accountIndex],
                                 matches: vector,
                                 coin: .ethereum,
                                 derivation: .custom,
                                 extendedPublicKey: Vectors.abandonEthereumExtendedPublicKey)
        }
    }

    func testEthereumPreviewReturnsNextPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 1, coin: .ethereum)

        XCTAssertEqual(accounts.count, 11)
        XCTAssertTrue(accounts.allSatisfy { $0.coin == .ethereum })
        XCTAssertTrue(accounts.allSatisfy { $0.extendedPublicKey == Vectors.abandonEthereumExtendedPublicKey })
        XCTAssertEqual(accounts.map { $0.previewDerivationIndex }, Array(11...21))

        for accountIndex in 11...21 {
            let vector = try XCTUnwrap(Vectors.abandonEthereumHDVectors.first { $0.index == accountIndex })
            assertPreviewAccount(accounts[accountIndex - 11],
                                 matches: vector,
                                 coin: .ethereum,
                                 derivation: .custom,
                                 extendedPublicKey: Vectors.abandonEthereumExtendedPublicKey)
        }
    }

    func testSolanaPreviewReturnsPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: .solana)

        XCTAssertEqual(accounts.count, 11)
        XCTAssertTrue(accounts.allSatisfy { $0.coin == .solana })
        XCTAssertTrue(accounts.allSatisfy { $0.extendedPublicKey.isEmpty })
        XCTAssertEqual(accounts[0].derivation, .solanaSolana)
        XCTAssertEqual(accounts[0].derivationPath, "m/44'/501'/0'/0'")
        XCTAssertEqual(accounts[1].derivation, .custom)
        XCTAssertEqual(accounts[1].derivationPath, "m/44'/501'/1'/0'")

        for accountIndex in 0...10 {
            let vector = try XCTUnwrap(Vectors.abandonSolanaHDVectors.first { $0.index == accountIndex })
            assertPreviewAccount(accounts[accountIndex],
                                 matches: vector,
                                 coin: .solana,
                                 derivation: vector.index == 0 ? .solanaSolana : .custom,
                                 extendedPublicKey: "")
        }
    }

    func testSolanaPreviewReturnsNextPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 1, coin: .solana)

        XCTAssertEqual(accounts.count, 11)
        XCTAssertTrue(accounts.allSatisfy { $0.coin == .solana })
        XCTAssertTrue(accounts.allSatisfy { $0.extendedPublicKey.isEmpty })
        XCTAssertTrue(accounts.allSatisfy { $0.derivation == .custom })
        XCTAssertEqual(accounts.map { $0.previewDerivationIndex }, Array(11...21))

        for accountIndex in 11...21 {
            let vector = try XCTUnwrap(Vectors.abandonSolanaHDVectors.first { $0.index == accountIndex })
            assertPreviewAccount(accounts[accountIndex - 11],
                                 matches: vector,
                                 coin: .solana,
                                 derivation: .custom,
                                 extendedPublicKey: "")
        }
    }

    func testPreviewRejectsOutOfRangePagesWithoutTrapping() throws {
        let hdWallet = try testHDWallet()

        for coin in [WalletCoin.ethereum, .solana] {
            assertPreviewRejectsPage(-1, coin: coin, hdWallet: hdWallet)
            assertPreviewRejectsPage(Int.max, coin: coin, hdWallet: hdWallet)
        }
    }

    func testMulticoinPreviewReturnsInterleavedPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: nil)
        let ethereumIndexTen = try XCTUnwrap(Vectors.abandonEthereumHDVectors.first { $0.index == 10 })
        let solanaIndexTen = try XCTUnwrap(Vectors.abandonSolanaHDVectors.first { $0.index == 10 })

        XCTAssertEqual(accounts.count, 22)
        XCTAssertEqual(accounts.filter { $0.coin == .ethereum }.count, 11)
        XCTAssertEqual(accounts.filter { $0.coin == .solana }.count, 11)
        XCTAssertTrue(accounts.allSatisfy { !$0.address.isEmpty })
        XCTAssertEqual(accounts[0].coin, .ethereum)
        XCTAssertEqual(accounts[0].derivationPath, WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 0))
        XCTAssertEqual(accounts[0].address, Vectors.abandonEthereumHDVectors[0].address)
        XCTAssertEqual(accounts[0].publicKey, Vectors.abandonEthereumHDVectors[0].publicKey)
        XCTAssertEqual(accounts[1].coin, .solana)
        XCTAssertEqual(accounts[1].derivationPath, "m/44'/501'/0'/0'")
        XCTAssertEqual(accounts[1].address, Vectors.abandonSolanaHDVectors[0].address)
        XCTAssertEqual(accounts[1].publicKey, Vectors.abandonSolanaHDVectors[0].publicKey)
        XCTAssertEqual(accounts[2].coin, .ethereum)
        XCTAssertEqual(accounts[2].derivationPath, WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 1))
        XCTAssertEqual(accounts[2].address, Vectors.abandonEthereumHDVectors[1].address)
        XCTAssertEqual(accounts[2].publicKey, Vectors.abandonEthereumHDVectors[1].publicKey)
        XCTAssertEqual(accounts[3].coin, .solana)
        XCTAssertEqual(accounts[3].derivationPath, "m/44'/501'/1'/0'")
        XCTAssertEqual(accounts[3].address, Vectors.abandonSolanaHDVectors[1].address)
        XCTAssertEqual(accounts[3].publicKey, Vectors.abandonSolanaHDVectors[1].publicKey)
        XCTAssertEqual(accounts[20].address, ethereumIndexTen.address)
        XCTAssertEqual(accounts[21].address, solanaIndexTen.address)
        XCTAssertEqual(accounts.prefix(6).map { $0.previewDerivationIndex }, [0, 0, 1, 1, 2, 2])
    }

    func testMulticoinPreviewCollectorInterleavesSuccessfulCoins() throws {
        let hdWallet = try testHDWallet()
        let ethereumAccounts = Array(try WalletsManager.shared.previewAccounts(hdWallet: hdWallet, page: 0, coin: .ethereum).prefix(2))
        let solanaAccounts = Array(try WalletsManager.shared.previewAccounts(hdWallet: hdWallet, page: 0, coin: .solana).prefix(2))

        let accounts = try WalletsManager.collectPreviewAccounts(coins: [.ethereum, .solana]) { coin in
            switch coin {
            case .ethereum:
                return ethereumAccounts
            case .solana:
                return solanaAccounts
            }
        }

        XCTAssertEqual(accounts.map { $0.previewAccountKey }, [
            ethereumAccounts[0].previewAccountKey,
            solanaAccounts[0].previewAccountKey,
            ethereumAccounts[1].previewAccountKey,
            solanaAccounts[1].previewAccountKey,
        ])
    }

    func testMulticoinPreviewPreservesSuccessfulCoinsWhenOneFails() throws {
        let ethereumAccount = WalletAccount(address: "0x0000000000000000000000000000000000000001",
                                      coin: .ethereum,
                                      derivation: .custom,
                                      derivationPath: "m/44'/60'/0'/0/0",
                                      publicKey: "public-key",
                                      extendedPublicKey: "extended-public-key")

        let accounts = try WalletsManager.collectPreviewAccounts(coins: [.solana, .ethereum]) { coin in
            if coin == .solana {
                throw PreviewTestError.failed
            }

            return [ethereumAccount]
        }

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.address, ethereumAccount.address)
    }

    func testMulticoinPreviewRethrowsWhenAllCoinsFail() {
        XCTAssertThrowsError(try WalletsManager.collectPreviewAccounts(coins: [.solana]) { _ in
            throw PreviewTestError.failed
        })
    }

    func testWalletLookupPreservesCoinAndAddressNormalization() throws {
        let key = try XCTUnwrap(
            WalletStoredKey.importJSON(json: Vectors.walletCoreJSONMnemonicFixture)
        )
        let solana = WalletAccount(
            address: Vectors.solanaAddressFromPublicKey,
            coin: .solana,
            derivation: .custom,
            derivationPath: "m/44'/501'/0'",
            publicKey: Vectors.solanaAddressPublicKey,
            extendedPublicKey: ""
        )
        key.addAccountDerivation(
            address: solana.address,
            coin: solana.coin,
            derivation: solana.derivation,
            derivationPath: solana.derivationPath,
            publicKey: solana.publicKey,
            extendedPublicKey: solana.extendedPublicKey
        )
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: "wallet")]
        reader.walletData = ["wallet": try XCTUnwrap(key.exportJSON())]
        let manager = WalletsManager(
            keychain: Keychain(copyMatching: reader.copyMatching)
        )

        XCTAssertTrue(manager.reloadFromStore())
        let ethereum = try XCTUnwrap(
            manager.wallets.first?.accounts.first(where: { $0.coin == .ethereum })
        )
        XCTAssertEqual(
            manager.getWalletAndAccount(
                coin: .ethereum,
                address: ethereum.address.uppercased()
            )?.1,
            ethereum
        )
        XCTAssertEqual(
            manager.getWalletAndAccount(coin: .solana, address: solana.address)?.1,
            solana
        )
        XCTAssertNotEqual(solana.address, solana.address.lowercased())
        XCTAssertNil(
            manager.getWalletAndAccount(
                coin: .solana,
                address: solana.address.lowercased()
            )
        )
        XCTAssertNil(
            manager.getWalletAndAccount(coin: .solana, address: ethereum.address)
        )
    }

    func testPrivateKeyLookupUsesInjectedKeychainPassword() throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: "wallet")]
        reader.walletData = ["wallet": Vectors.walletCoreJSONPrivateKeyFixture]
        reader.passwordData = Vectors.walletCoreJSONPrivateKeyPassword
        let manager = WalletsManager(
            keychain: Keychain(copyMatching: reader.copyMatching)
        )

        XCTAssertTrue(manager.reloadFromStore())
        let wallet = try XCTUnwrap(manager.wallets.first)
        let account = try XCTUnwrap(wallet.accounts.first)
        let privateKey = try XCTUnwrap(
            manager.getPrivateKey(walletId: wallet.id, account: account)
        )
        privateKey.withData {
            XCTAssertEqual($0, Vectors.walletCoreJSONPrivateKeyData)
        }
        XCTAssertEqual(reader.passwordReadCount, 1)
    }

    func testKeychainWalletOrderingIsDeterministicForTiedAndMissingDates() throws {
        let reader = KeychainCopyMatchingStub()
        let earlier = Date(timeIntervalSince1970: 10)
        let tied = Date(timeIntervalSince1970: 20)
        reader.attributes = [
            reader.walletAttributes(id: "missing-b"),
            reader.walletAttributes(id: "tied-b", createdAt: tied),
            reader.walletAttributes(id: "earlier", createdAt: earlier),
            reader.walletAttributes(id: "missing-a"),
            reader.walletAttributes(id: "tied-a", createdAt: tied),
        ]
        let keychain = Keychain(copyMatching: reader.copyMatching)
        let expected = ["earlier", "tied-a", "tied-b", "missing-a", "missing-b"]

        XCTAssertEqual(try keychain.readAllWalletIDs(), expected)
        reader.attributes.reverse()
        XCTAssertEqual(try keychain.readAllWalletIDs(), expected)
    }

    func testWalletReloadPreservesLastGoodStateOnPartialReadFailure() throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [
            reader.walletAttributes(id: "wallet-a", createdAt: Date(timeIntervalSince1970: 10)),
            reader.walletAttributes(id: "wallet-b", createdAt: Date(timeIntervalSince1970: 20)),
        ]
        reader.walletData = [
            "wallet-a": Vectors.walletCoreJSONPrivateKeyFixture,
            "wallet-b": Vectors.walletCoreJSONPrivateKeyFixture,
        ]
        var metadataReloadCount = 0
        let manager = WalletsManager(
            keychain: Keychain(copyMatching: reader.copyMatching),
            reloadMetadata: { metadataReloadCount += 1 }
        )

        XCTAssertTrue(manager.reloadFromStore())
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet-a", "wallet-b"])
        XCTAssertEqual(metadataReloadCount, 1)

        reader.walletReadStatuses["wallet-b"] = errSecInteractionNotAllowed
        XCTAssertFalse(manager.reloadFromStore())
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet-a", "wallet-b"])
        XCTAssertEqual(metadataReloadCount, 1)

        reader.walletReadStatuses["wallet-b"] = errSecItemNotFound
        XCTAssertTrue(manager.reloadFromStore())
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet-a"])
        XCTAssertEqual(metadataReloadCount, 2)
    }

    func testWalletReloadTreatsInvalidJSONAsSkippableAndEmptyStoreAsAvailable() {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [
            reader.walletAttributes(id: "valid"),
            reader.walletAttributes(id: "invalid"),
        ]
        reader.walletData = [
            "valid": Vectors.walletCoreJSONPrivateKeyFixture,
            "invalid": Data("not-json".utf8),
        ]
        var metadataReloadCount = 0
        let manager = WalletsManager(
            keychain: Keychain(copyMatching: reader.copyMatching),
            reloadMetadata: { metadataReloadCount += 1 }
        )

        XCTAssertTrue(manager.reloadFromStore())
        XCTAssertEqual(manager.wallets.map(\.id), ["valid"])
        XCTAssertEqual(metadataReloadCount, 1)

        reader.attributesStatus = errSecItemNotFound
        XCTAssertTrue(manager.reloadFromStore())
        XCTAssertTrue(manager.wallets.isEmpty)
        XCTAssertEqual(metadataReloadCount, 2)
    }

    func testWalletReloadPreservesLastGoodStateWhenEnumerationIsUnavailable() {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: "wallet")]
        reader.walletData = ["wallet": Vectors.walletCoreJSONPrivateKeyFixture]
        let manager = WalletsManager(
            keychain: Keychain(copyMatching: reader.copyMatching)
        )

        XCTAssertTrue(manager.reloadFromStore())
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet"])

        reader.attributesStatus = errSecInteractionNotAllowed
        XCTAssertFalse(manager.reloadFromStore())
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet"])
    }

    func testFailedInitialStartWaitsForExplicitReload() {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: "wallet")]
        reader.walletData = ["wallet": Vectors.walletCoreJSONPrivateKeyFixture]
        reader.attributesStatus = errSecInteractionNotAllowed
        var metadataReloadCount = 0
        var localPublicationCount = 0
        let manager = WalletsManager(
            keychain: Keychain(copyMatching: reader.copyMatching),
            reloadMetadata: { metadataReloadCount += 1 },
            publishLocalChange: { localPublicationCount += 1 }
        )

        XCTAssertFalse(manager.start())
        XCTAssertEqual(metadataReloadCount, 0)
        XCTAssertEqual(localPublicationCount, 0)

        reader.attributesStatus = errSecSuccess
        XCTAssertTrue(manager.reloadFromStore())

        XCTAssertEqual(manager.wallets.map(\.id), ["wallet"])
        XCTAssertEqual(metadataReloadCount, 1)
        XCTAssertEqual(localPublicationCount, 0)
    }

    func testExternalWalletChangeRetriesOnlyOnNextExplicitEvent() {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: "wallet-a")]
        reader.walletData = ["wallet-a": Vectors.walletCoreJSONPrivateKeyFixture]
        var metadataReloadCount = 0
        var localPublicationCount = 0
        let manager = WalletsManager(
            keychain: Keychain(copyMatching: reader.copyMatching),
            reloadMetadata: { metadataReloadCount += 1 },
            publishLocalChange: { localPublicationCount += 1 }
        )

        XCTAssertTrue(manager.reloadFromStore())
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet-a"])

        reader.attributes = [reader.walletAttributes(id: "wallet-b")]
        reader.walletData = ["wallet-b": Vectors.walletCoreJSONPrivateKeyFixture]
        reader.attributesStatus = errSecInteractionNotAllowed
        manager.handleExternalWalletStoreChange()

        XCTAssertEqual(manager.wallets.map(\.id), ["wallet-a"])
        XCTAssertEqual(metadataReloadCount, 1)
        XCTAssertEqual(localPublicationCount, 0)

        reader.attributesStatus = errSecSuccess
        manager.handleExternalWalletStoreChange()

        XCTAssertEqual(manager.wallets.map(\.id), ["wallet-b"])
        XCTAssertEqual(metadataReloadCount, 2)
        XCTAssertEqual(localPublicationCount, 1)
    }

    private func testHDWallet(file: StaticString = #filePath, line: UInt = #line) throws -> WalletHDWallet {
        guard let wallet = WalletHDWallet(mnemonic: mnemonic, passphrase: "") else {
            XCTFail("Expected test mnemonic to create HD wallet", file: file, line: line)
            throw PreviewTestError.failed
        }

        return wallet
    }

    private func assertPreviewRejectsPage(_ page: Int,
                                          coin: WalletCoin,
                                          hdWallet: WalletHDWallet,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) {
        XCTAssertThrowsError(try WalletsManager.shared.previewAccounts(hdWallet: hdWallet, page: page, coin: coin),
                             file: file,
                             line: line) { error in
            guard case WalletsManager.Error.failedToDeriveAccount = error else {
                XCTFail("Expected failedToDeriveAccount, got \(error)", file: file, line: line)
                return
            }
        }
    }

    private func assertPreviewAccount(_ account: WalletAccount,
                                      matches vector: (index: Int, path: String, privateKey: Data, publicKey: String, address: String),
                                      coin: WalletCoin,
                                      derivation: WalletDerivation,
                                      extendedPublicKey: String,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        XCTAssertEqual(account.address, vector.address, file: file, line: line)
        XCTAssertEqual(account.coin, coin, file: file, line: line)
        XCTAssertEqual(account.derivation, derivation, file: file, line: line)
        XCTAssertEqual(account.derivationPath, vector.path, file: file, line: line)
        XCTAssertEqual(account.publicKey, vector.publicKey, file: file, line: line)
        XCTAssertEqual(account.extendedPublicKey, extendedPublicKey, file: file, line: line)
        XCTAssertEqual(account.previewDerivationIndex, vector.index, file: file, line: line)
    }

}

final class KeychainCopyMatchingStub {
    private static let walletPrefix = "org.lil.wallet.wallet."
    private static let passwordKey = "org.lil.wallet.password"

    var attributes = [[String: Any]]()
    var attributesStatus = errSecSuccess
    var passwordData: Data?
    var passwordReadCount = 0
    var walletData = [String: Data]()
    var walletReadStatuses = [String: OSStatus]()

    func walletAttributes(id: String, createdAt: Date? = nil) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecAttrAccount as String: Self.walletPrefix + id,
        ]
        attributes[kSecAttrCreationDate as String] = createdAt
        return attributes
    }

    func copyMatching(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        let query = query as NSDictionary
        if query[kSecReturnAttributes as String] as? Bool == true {
            guard attributesStatus == errSecSuccess else {
                return attributesStatus
            }
            result?.pointee = attributes as CFArray
            return errSecSuccess
        }

        guard let key = query[kSecAttrAccount as String] as? String else {
            return errSecItemNotFound
        }
        if key == Self.passwordKey {
            passwordReadCount += 1
            guard let passwordData else { return errSecItemNotFound }
            result?.pointee = passwordData as CFData
            return errSecSuccess
        }
        guard key.hasPrefix(Self.walletPrefix) else { return errSecItemNotFound }
        let id = String(key.dropFirst(Self.walletPrefix.count))
        if let status = walletReadStatuses[id], status != errSecSuccess {
            return status
        }
        guard let data = walletData[id] else {
            return errSecItemNotFound
        }
        result?.pointee = data as CFData
        return errSecSuccess
    }
}
