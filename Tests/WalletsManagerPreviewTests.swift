// ∅ 2026 lil org

import Foundation
import Synchronization
import Security
import XCTest
@testable import Big_Wallet

private typealias Vectors = WalletCoreProxyTestVectors

@MainActor
final class WalletsManagerPreviewTests: XCTestCase {

    private enum PreviewTestError: Error {
        case failed
    }

    private let mnemonic = Vectors.abandonMnemonic

    func testRepositoryReadsStayOffTheMainActor() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: "wallet")]
        reader.walletData = ["wallet": Vectors.walletCoreJSONPrivateKeyFixture]
        let readThreads = Mutex([Bool]())
        let manager = WalletsManager(keychain: Keychain(copyMatching: { query, result in
            readThreads.withLock { $0.append(Thread.isMainThread) }
            return reader.copyMatching(query, result)
        }))

        await assertWalletReload(manager)

        let reads = readThreads.withLock { $0 }
        XCTAssertFalse(reads.isEmpty)
        XCTAssertFalse(reads.contains(true))
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet"])
    }

    func testInvalidatedPreviewDiscardsItsPendingFirstPage() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: "wallet")]
        reader.walletData = ["wallet": Vectors.walletCoreJSONMnemonicFixture]
        reader.passwordData = Vectors.walletCoreJSONMnemonicPassword
        let readingPassword = expectation(description: "Preview read its password off the main actor")
        let releaseRead = DispatchSemaphore(value: 0)
        defer { releaseRead.signal() }
        let manager = WalletsManager(keychain: Keychain(copyMatching: { query, result in
            let attributes = query as NSDictionary
            if attributes[kSecAttrAccount as String] as? String == "org.lil.wallet.password" {
                readingPassword.fulfill()
                releaseRead.wait()
            }
            return reader.copyMatching(query, result)
        }))
        await assertWalletReload(manager)
        let wallet = try XCTUnwrap(manager.wallets.first)
        let pager = manager.previewAccountsPager(wallet: wallet)
        let preview = Task { await pager.reset() }
        await fulfillment(of: [readingPassword], timeout: 2)

        pager.invalidate()
        releaseRead.signal()

        let accounts = await preview.value
        XCTAssertNil(accounts)
        let nextPage = await pager.previewMoreIfNeeded()
        XCTAssertNil(nextPage)
    }

    func testReviewCatalogPreservesAccountMetadataAndSurvivesSourceReload() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [
            reader.walletAttributes(id: "wallet-a"),
            reader.walletAttributes(id: "wallet-b"),
        ]
        reader.walletData = [
            "wallet-a": Vectors.walletCoreJSONMnemonicFixture,
            "wallet-b": Vectors.walletCoreJSONPrivateKeyFixture,
        ]
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        await assertWalletReload(manager)
        let originalAccounts = manager.wallets.flatMap { wallet in
            wallet.accounts.map { SpecificWalletAccount(walletId: wallet.id, account: $0) }
        }
        let catalog = try XCTUnwrap(manager.reviewCatalog())
        XCTAssertEqual(catalog.orderedAccounts, originalAccounts)
        XCTAssertEqual(catalog.orderedAccounts.map(\.walletId), ["wallet-a", "wallet-b"])
        XCTAssertNil(catalog.identity.generation)
        let persistedCatalog = try JSONDecoder().decode(
            WalletAccountCatalog.self,
            from: catalog.identity.catalogData
        )
        XCTAssertEqual(persistedCatalog.accounts.map(\.normalizedAddress), originalAccounts.map {
            $0.account.coin.normalizedAddress($0.account.address)
        })

        reader.attributes = []
        await assertWalletReload(manager)
        let emptyCatalog = try XCTUnwrap(manager.reviewCatalog())
        XCTAssertTrue(emptyCatalog.orderedAccounts.isEmpty)
        XCTAssertNotEqual(emptyCatalog.identity, catalog.identity)
        XCTAssertEqual(catalog.orderedAccounts, originalAccounts)
    }

    func testEthereumPreviewReturnsPageOfAccounts() async throws {
        let accounts = try WalletAccountDerivation.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: .ethereum)

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

    func testEthereumPreviewReturnsNextPageOfAccounts() async throws {
        let accounts = try WalletAccountDerivation.previewAccounts(hdWallet: testHDWallet(), page: 1, coin: .ethereum)

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

    func testSolanaPreviewReturnsPageOfAccounts() async throws {
        let accounts = try WalletAccountDerivation.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: .solana)

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

    func testSolanaPreviewReturnsNextPageOfAccounts() async throws {
        let accounts = try WalletAccountDerivation.previewAccounts(hdWallet: testHDWallet(), page: 1, coin: .solana)

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

    func testPreviewRejectsOutOfRangePagesWithoutTrapping() async throws {
        let hdWallet = try testHDWallet()

        for coin in [WalletCoin.ethereum, .solana] {
            assertPreviewRejectsPage(-1, coin: coin, hdWallet: hdWallet)
            assertPreviewRejectsPage(Int.max, coin: coin, hdWallet: hdWallet)
        }
    }

    func testMulticoinPreviewReturnsInterleavedPageOfAccounts() async throws {
        let accounts = try WalletAccountDerivation.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: nil)
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

    func testMulticoinPreviewCollectorInterleavesSuccessfulCoins() async throws {
        let hdWallet = try testHDWallet()
        let ethereumAccounts = Array(try WalletAccountDerivation.previewAccounts(hdWallet: hdWallet, page: 0, coin: .ethereum).prefix(2))
        let solanaAccounts = Array(try WalletAccountDerivation.previewAccounts(hdWallet: hdWallet, page: 0, coin: .solana).prefix(2))

        let accounts = try WalletAccountDerivation.collectPreviewAccounts(coins: [.ethereum, .solana]) { coin in
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

    func testMulticoinPreviewPreservesSuccessfulCoinsWhenOneFails() async throws {
        let ethereumAccount = WalletAccount(address: "0x0000000000000000000000000000000000000001",
                                      coin: .ethereum,
                                      derivation: .custom,
                                      derivationPath: "m/44'/60'/0'/0/0",
                                      publicKey: "public-key",
                                      extendedPublicKey: "extended-public-key")

        let accounts = try WalletAccountDerivation.collectPreviewAccounts(coins: [.solana, .ethereum]) { coin in
            if coin == .solana {
                throw PreviewTestError.failed
            }

            return [ethereumAccount]
        }

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.address, ethereumAccount.address)
    }

    func testMulticoinPreviewRethrowsWhenAllCoinsFail() async throws {
        XCTAssertThrowsError(try WalletAccountDerivation.collectPreviewAccounts(coins: [.solana]) { _ in
            throw PreviewTestError.failed
        })
    }

    func testReviewCatalogLookupPreservesCoinAndAddressNormalization() async throws {
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

        await assertWalletReload(manager)
        let catalog = try XCTUnwrap(manager.reviewCatalog())
        let ethereum = try XCTUnwrap(
            manager.wallets.first?.accounts.first(where: { $0.coin == .ethereum })
        )
        XCTAssertEqual(
            catalog.specificAccount(
                coin: .ethereum,
                address: ethereum.address.uppercased()
            )?.account,
            ethereum
        )
        XCTAssertEqual(
            catalog.specificAccount(coin: .solana, address: solana.address)?.account,
            solana
        )
        XCTAssertNotEqual(solana.address, solana.address.lowercased())
        XCTAssertNil(
            catalog.specificAccount(
                coin: .solana,
                address: solana.address.lowercased()
            )
        )
        XCTAssertNil(
            catalog.specificAccount(coin: .solana, address: ethereum.address)
        )
    }

    func testPrivateKeyExportUsesInjectedPasswordAndRevalidatesSource() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: "wallet")]
        reader.walletData = ["wallet": Vectors.walletCoreJSONPrivateKeyFixture]
        reader.passwordData = Vectors.walletCoreJSONPrivateKeyPassword
        let manager = WalletsManager(
            keychain: Keychain(copyMatching: reader.copyMatching)
        )

        await assertWalletReload(manager)
        let wallet = try XCTUnwrap(manager.wallets.first)
        let account = try XCTUnwrap(wallet.accounts.first)
        let exported = try await manager.exportPrivateKey(wallet: wallet, account: account)
        XCTAssertEqual(WalletCrypto.hexData(string: exported), Vectors.walletCoreJSONPrivateKeyData)
        XCTAssertEqual(reader.passwordReadCount, 2)
    }

    func testKeychainWalletOrderingIsDeterministicForTiedAndMissingDates() async throws {
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

    func testWalletReloadPreservesLastGoodStateOnPartialReadFailure() async throws {
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
        var publishedWalletIDs = [[String]]()
        weak var observedManager: WalletsManager?
        let manager = WalletsManager(
            keychain: Keychain(copyMatching: reader.copyMatching),
            reloadMetadata: { metadataReloadCount += 1 },
            publishLocalChange: {
                publishedWalletIDs.append(observedManager?.wallets.map(\.id) ?? [])
            }
        )
        observedManager = manager

        await assertWalletReload(manager)
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet-a", "wallet-b"])
        XCTAssertEqual(metadataReloadCount, 1)
        XCTAssertEqual(publishedWalletIDs, [["wallet-a", "wallet-b"]])

        reader.walletReadStatuses["wallet-b"] = errSecInteractionNotAllowed
        await assertWalletReload(manager, succeeds: false)
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet-a", "wallet-b"])
        XCTAssertEqual(metadataReloadCount, 1)
        XCTAssertEqual(publishedWalletIDs, [["wallet-a", "wallet-b"]])

        reader.walletReadStatuses["wallet-b"] = errSecItemNotFound
        await assertWalletReload(manager)
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet-a"])
        XCTAssertEqual(metadataReloadCount, 2)
        XCTAssertEqual(publishedWalletIDs, [["wallet-a", "wallet-b"], ["wallet-a"]])
    }

    func testWalletReloadTreatsInvalidJSONAsSkippableAndEmptyStoreAsAvailable() async throws {
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

        await assertWalletReload(manager)
        XCTAssertEqual(manager.wallets.map(\.id), ["valid"])
        XCTAssertEqual(metadataReloadCount, 1)

        reader.attributesStatus = errSecItemNotFound
        await assertWalletReload(manager)
        XCTAssertTrue(manager.wallets.isEmpty)
        XCTAssertEqual(metadataReloadCount, 2)
    }

    func testWalletReloadPreservesLastGoodStateWhenEnumerationIsUnavailable() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: "wallet")]
        reader.walletData = ["wallet": Vectors.walletCoreJSONPrivateKeyFixture]
        let manager = WalletsManager(
            keychain: Keychain(copyMatching: reader.copyMatching)
        )

        await assertWalletReload(manager)
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet"])

        reader.attributesStatus = errSecInteractionNotAllowed
        await assertWalletReload(manager, succeeds: false)
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet"])
    }

    func testFailedInitialStartWaitsForExplicitReload() async throws {
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

        let started = await manager.start()
        XCTAssertFalse(started)
        XCTAssertEqual(metadataReloadCount, 0)
        XCTAssertEqual(localPublicationCount, 0)

        reader.attributesStatus = errSecSuccess
        await assertWalletReload(manager)

        XCTAssertEqual(manager.wallets.map(\.id), ["wallet"])
        XCTAssertEqual(metadataReloadCount, 1)
        XCTAssertEqual(localPublicationCount, 1)
    }

    func testExternalWalletChangeRetriesOnlyOnNextExplicitEvent() async throws {
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

        await assertWalletReload(manager)
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet-a"])

        reader.attributes = [reader.walletAttributes(id: "wallet-b")]
        reader.walletData = ["wallet-b": Vectors.walletCoreJSONPrivateKeyFixture]
        reader.attributesStatus = errSecInteractionNotAllowed
        await manager.handleExternalWalletStoreChange()

        XCTAssertEqual(manager.wallets.map(\.id), ["wallet-a"])
        XCTAssertEqual(metadataReloadCount, 1)
        XCTAssertEqual(localPublicationCount, 1)

        reader.attributesStatus = errSecSuccess
        await manager.handleExternalWalletStoreChange()

        XCTAssertEqual(manager.wallets.map(\.id), ["wallet-b"])
        XCTAssertEqual(metadataReloadCount, 2)
        XCTAssertEqual(localPublicationCount, 2)
    }

    func testExternalReloadPublishesAppliedStateDespiteLateCancellation() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: "wallet")]
        reader.walletData = ["wallet": Vectors.walletCoreJSONPrivateKeyFixture]
        var metadataReloadCount = 0
        var localPublicationCount = 0
        let manager = WalletsManager(
            keychain: Keychain(copyMatching: reader.copyMatching),
            reloadMetadata: {
                metadataReloadCount += 1
                if metadataReloadCount == 2 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            },
            publishLocalChange: { localPublicationCount += 1 }
        )
        await assertWalletReload(manager)
        XCTAssertEqual(manager.wallets.count, 1)
        reader.attributes = []

        let reload = Task { await manager.handleExternalWalletStoreChange() }
        await reload.value

        XCTAssertTrue(reload.isCancelled)
        XCTAssertTrue(manager.wallets.isEmpty)
        XCTAssertEqual(localPublicationCount, 2)
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
        XCTAssertThrowsError(try WalletAccountDerivation.previewAccounts(hdWallet: hdWallet, page: page, coin: coin),
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

@MainActor
func assertWalletReload(_ manager: WalletsManager, succeeds: Bool = true, file: StaticString = #filePath, line: UInt = #line) async {
    let loaded = await manager.reloadFromStore()
    XCTAssertEqual(loaded, succeeds, file: file, line: line)
}

final class KeychainCopyMatchingStub: Sendable {
    private static let walletPrefix = "org.lil.wallet.wallet."
    private static let passwordKey = "org.lil.wallet.password"

    private struct Attribute: Sendable {
        let account: String?
        let createdAt: Date?

        var dictionary: [String: Any] {
            var result = [String: Any]()
            result[kSecAttrAccount as String] = account
            result[kSecAttrCreationDate as String] = createdAt
            return result
        }
    }

    private struct State: Sendable {
        var attributes = [Attribute]()
        var attributesStatus = errSecSuccess
        var passwordData: Data?
        var passwordReadCount = 0
        var walletData = [String: Data]()
        var walletReadCount = 0
        var walletReadStatuses = [String: OSStatus]()
    }

    private let state = Mutex(State())

    var attributes: [[String: Any]] {
        get { state.withLock { $0.attributes }.map(\.dictionary) }
        set {
            let attributes = newValue.map { Attribute(account: $0[kSecAttrAccount as String] as? String, createdAt: $0[kSecAttrCreationDate as String] as? Date) }
            state.withLock { $0.attributes = attributes }
        }
    }

    var attributesStatus: OSStatus {
        get { state.withLock { $0.attributesStatus } }
        set { state.withLock { $0.attributesStatus = newValue } }
    }

    var passwordData: Data? {
        get { state.withLock { $0.passwordData } }
        set { state.withLock { $0.passwordData = newValue } }
    }

    var passwordReadCount: Int { state.withLock { $0.passwordReadCount } }

    var walletData: [String: Data] {
        get { state.withLock { $0.walletData } }
        set { state.withLock { $0.walletData = newValue } }
    }

    var walletReadCount: Int { state.withLock { $0.walletReadCount } }

    var walletReadStatuses: [String: OSStatus] {
        get { state.withLock { $0.walletReadStatuses } }
        set { state.withLock { $0.walletReadStatuses = newValue } }
    }

    func walletAttributes(id: String, createdAt: Date? = nil) -> [String: Any] {
        Attribute(account: Self.walletPrefix + id, createdAt: createdAt).dictionary
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let query = query as NSDictionary
        return state.withLock { state in
            if query[kSecReturnAttributes as String] as? Bool == true {
                guard state.attributesStatus == errSecSuccess else { return state.attributesStatus }
                result?.pointee = state.attributes.map(\.dictionary) as CFArray
                return errSecSuccess
            }
            guard let key = query[kSecAttrAccount as String] as? String else { return errSecItemNotFound }
            if key == Self.passwordKey {
                state.passwordReadCount += 1
                guard let passwordData = state.passwordData else { return errSecItemNotFound }
                result?.pointee = passwordData as CFData
                return errSecSuccess
            }
            guard key.hasPrefix(Self.walletPrefix) else { return errSecItemNotFound }
            state.walletReadCount += 1
            let id = String(key.dropFirst(Self.walletPrefix.count))
            if let status = state.walletReadStatuses[id], status != errSecSuccess { return status }
            guard let data = state.walletData[id] else { return errSecItemNotFound }
            result?.pointee = data as CFData
            return errSecSuccess
        }
    }
}
