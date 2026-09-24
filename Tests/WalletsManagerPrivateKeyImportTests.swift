// ∅ 2026 lil org

import CryptoKit
import Foundation
import Security
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

#if os(macOS)
private struct WalletSourceMutationStub: WalletSourceMutating {
    let onRevoke: (WalletAuthorityRemoval) throws -> Void

    func perform<Payload, Result>(
        preparing: () throws -> PreparedWalletSourceMutation<Payload>,
        beforeCommit: () throws -> Void,
        commit: (Payload) throws -> Result
    ) throws -> Result {
        let prepared = try preparing()
        try beforeCommit()
        for removal in prepared.authorityRemovals {
            try onRevoke(removal)
        }
        return try commit(prepared.payload)
    }
}

private struct ObservedWalletSourceMutator: WalletSourceMutating {
    let base: any WalletSourceMutating
    var beforeTransaction: () throws -> Void = {}
    var beforePreparation: () -> Void = {}
    var afterTransaction: () -> Void = {}

    func perform<Payload, Result>(
        preparing: () throws -> PreparedWalletSourceMutation<Payload>,
        beforeCommit: () throws -> Void,
        commit: (Payload) throws -> Result
    ) throws -> Result {
        try beforeTransaction()
        defer { afterTransaction() }
        return try base.perform(
            preparing: {
                beforePreparation()
                return try preparing()
            },
            beforeCommit: beforeCommit,
            commit: commit
        )
    }
}

@MainActor
final class WalletRemovalIntegrationTests: XCTestCase {

    private enum TestError: Error {
        case cleanupFailed
    }

    func testWalletDeletionRevokesBeforeSourceRemovalAndPreservesSiblingMetadata() async throws {
        let fixture = try RemovalFixture()
        var removals = [WalletAuthorityRemoval]()
        let manager = fixture.manager { removal in
            removals.append(removal)
            fixture.keychain.events.append("cleanup")
            XCTAssertNotNil(fixture.keychain.walletData[fixture.walletID])
        }
        XCTAssertTrue(manager.reloadFromStore())
        let wallet = try XCTUnwrap(manager.wallets.first { $0.id == fixture.walletID })
        let sibling = try XCTUnwrap(manager.wallets.first { $0.id == fixture.siblingID })
        let account = try XCTUnwrap(wallet.accounts.first)
        WalletsMetadataService.saveWalletName("Removed wallet", wallet: wallet)
        WalletsMetadataService.saveAccountName("Removed account", wallet: wallet, account: account)
        WalletsMetadataService.saveWalletName("Sibling wallet", wallet: sibling)
        WalletsMetadataService.saveAccountName("Sibling account", wallet: sibling, account: account)
        defer { fixture.clearMetadata() }

        try await manager.delete(wallet: wallet)

        XCTAssertEqual(removals.count, 1)
        guard case .wallet(let id)? = removals.first else { return XCTFail("Expected whole-wallet revocation") }
        XCTAssertEqual(id, fixture.walletID)
        XCTAssertEqual(fixture.keychain.events, ["cleanup", "delete"])
        XCTAssertNil(fixture.keychain.walletData[fixture.walletID])
        XCTAssertNotNil(fixture.keychain.walletData[fixture.siblingID])
        XCTAssertEqual(manager.wallets.map(\.id), [fixture.siblingID])
        XCTAssertNil(WalletsMetadataService.getWalletName(wallet: wallet))
        XCTAssertNil(WalletsMetadataService.getAccountName(walletId: wallet.id, account: account))
        XCTAssertEqual(WalletsMetadataService.getWalletName(wallet: sibling), "Sibling wallet")
        XCTAssertEqual(WalletsMetadataService.getAccountName(walletId: sibling.id, account: account), "Sibling account")
    }

    func testBothAccountRemovalPathsPreserveConcurrentAdditionsAndSiblingMetadata() async throws {
        for useEnabledAccounts in [false, true] {
            let fixture = try RemovalFixture()
            var removedAccounts = Set<WalletAccountDescriptor>()
            let manager = fixture.manager { removal in
                guard case .accounts(let accounts) = removal else {
                    return XCTFail("Expected account-scoped revocation")
                }
                removedAccounts.formUnion(accounts)
                fixture.keychain.events.append("cleanup")
            }
            XCTAssertTrue(manager.reloadFromStore())
            let wallet = try XCTUnwrap(manager.wallets.first { $0.id == fixture.walletID })
            let sibling = try XCTUnwrap(manager.wallets.first { $0.id == fixture.siblingID })
            let retained = wallet.accounts[0]
            let removed = wallet.accounts[1]
            let concurrent = fixture.additionalAccount(index: 2)
            fixture.keychain.walletData[fixture.walletID] = try fixture.walletData(adding: concurrent)
            WalletsMetadataService.saveWalletName("Kept wallet", wallet: wallet)
            WalletsMetadataService.saveAccountName("Retained", wallet: wallet, account: retained)
            WalletsMetadataService.saveAccountName("Removed", wallet: wallet, account: removed)
            WalletsMetadataService.saveAccountName("Concurrent", wallet: wallet, account: concurrent)
            WalletsMetadataService.saveAccountName("Other wallet", wallet: sibling, account: removed)
            defer { fixture.clearMetadata() }

            if useEnabledAccounts {
                try await manager.update(wallet: wallet, enabledAccounts: [retained])
            } else {
                try await manager.update(wallet: wallet, removeAccounts: [removed])
            }

            XCTAssertEqual(removedAccounts, [WalletAccountDescriptor(walletID: wallet.id, account: removed)])
            XCTAssertEqual(fixture.keychain.events, ["cleanup", "update"])
            let persisted = try fixture.persistedWallet()
            XCTAssertEqual(Set(persisted.accounts.map(\.previewAccountKey)), [retained.previewAccountKey, concurrent.previewAccountKey])
            let current = try XCTUnwrap(manager.wallets.first { $0.id == wallet.id })
            XCTAssertEqual(current.accounts, persisted.accounts)
            XCTAssertEqual(WalletsMetadataService.getWalletName(wallet: wallet), "Kept wallet")
            XCTAssertNil(WalletsMetadataService.getAccountName(walletId: wallet.id, account: removed))
            XCTAssertEqual(WalletsMetadataService.getAccountName(walletId: wallet.id, account: retained), "Retained")
            XCTAssertEqual(WalletsMetadataService.getAccountName(walletId: wallet.id, account: concurrent), "Concurrent")
            XCTAssertEqual(WalletsMetadataService.getAccountName(walletId: sibling.id, account: removed), "Other wallet")
        }
    }

    func testAccountAddedAndGrantedAtTransactionEntrySurvivesBothRemovalPaths() async throws {
        for useEnabledAccounts in [false, true] {
            let fixture = try RemovalFixture()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wallet-edit-race-\(UUID().uuidString)")
            defer {
                try? FileManager.default.removeItem(at: directory)
                fixture.clearMetadata()
            }
            let store = ExtensionRequestFileStore(rootURL: directory, directoryBoundary: directory)
            let staleWallet = try fixture.persistedWallet()
            let retained = staleWallet.accounts[0]
            let removed = staleWallet.accounts[1]
            let concurrent = fixture.additionalAccount(index: 2)
            let removedDescriptor = WalletAccountDescriptor(walletID: staleWallet.id, account: removed)
            let concurrentDescriptor = WalletAccountDescriptor(walletID: staleWallet.id, account: concurrent)
            let removedOrigin = "https://removed-account.example"
            let concurrentOrigin = "https://concurrent-account.example"
            try grant(removedDescriptor, in: store, id: 1, origin: removedOrigin)
            WalletsMetadataService.saveAccountName("Removed", wallet: staleWallet, account: removed)
            var transactionEntries = 0
            var insideTransaction = false
            let manager = fixture.transactionManager(ObservedWalletSourceMutator(
                base: store,
                beforeTransaction: {
                    transactionEntries += 1
                    fixture.keychain.walletData[fixture.walletID] = try fixture.walletData(adding: concurrent)
                    try self.grant(concurrentDescriptor, in: store, id: 2, origin: concurrentOrigin)
                    WalletsMetadataService.saveAccountName("Concurrent", wallet: staleWallet, account: concurrent)
                },
                beforePreparation: { insideTransaction = true },
                afterTransaction: { insideTransaction = false }
            ))
            XCTAssertTrue(manager.reloadFromStore())
            fixture.keychain.beforeWalletRead = { _ in
                XCTAssertTrue(insideTransaction, "Source accounts must be read after acquiring the transaction")
            }
            fixture.keychain.beforeWalletWrite = {
                XCTAssertTrue(insideTransaction, "Source accounts must be written before releasing the transaction")
            }

            if useEnabledAccounts {
                try await manager.update(wallet: staleWallet, enabledAccounts: [retained])
            } else {
                try await manager.update(wallet: staleWallet, removeAccounts: [removed])
            }
            fixture.keychain.beforeWalletRead = nil
            fixture.keychain.beforeWalletWrite = nil

            XCTAssertEqual(transactionEntries, 1)
            XCTAssertEqual(fixture.keychain.events, ["update"])
            let persisted = try fixture.persistedWallet()
            XCTAssertEqual(Set(persisted.accounts.map(\.previewAccountKey)), [retained.previewAccountKey, concurrent.previewAccountKey])
            XCTAssertEqual(manager.wallets.first { $0.id == staleWallet.id }?.accounts, persisted.accounts)
            XCTAssertNil(WalletsMetadataService.getAccountName(walletId: staleWallet.id, account: removed))
            XCTAssertEqual(WalletsMetadataService.getAccountName(walletId: staleWallet.id, account: concurrent), "Concurrent")
            guard case .snapshot(let removedState) = store.configurationSnapshot(configurationKey: removedOrigin, profileIdentifier: nil),
                  case .snapshot(let concurrentState) = store.configurationSnapshot(configurationKey: concurrentOrigin, profileIdentifier: nil) else {
                return XCTFail("Expected current authority snapshots")
            }
            XCTAssertNil(removedState.ethereumAccount)
            XCTAssertEqual(concurrentState.ethereumAccount, concurrentDescriptor)
        }
    }

    func testAccountAdditionsAndWalletImportsUseTheSourceMutationBoundary() async throws {
        let fixture = try RemovalFixture()
        var transactionEntries = 0
        var revocations = 0
        var insideTransaction = false
        let manager = fixture.transactionManager(ObservedWalletSourceMutator(
            base: WalletSourceMutationStub(onRevoke: { _ in revocations += 1 }),
            beforePreparation: {
                transactionEntries += 1
                insideTransaction = true
            },
            afterTransaction: { insideTransaction = false }
        ))
        XCTAssertTrue(manager.reloadFromStore())
        let wallet = try XCTUnwrap(manager.wallets.first { $0.id == fixture.walletID })
        let added = fixture.additionalAccount(index: 2)
        fixture.keychain.beforeWalletRead = { _ in XCTAssertTrue(insideTransaction) }
        fixture.keychain.beforeWalletWrite = { XCTAssertTrue(insideTransaction) }

        try await manager.update(wallet: wallet, enabledAccounts: wallet.accounts + [added])

        XCTAssertEqual(transactionEntries, 1)
        XCTAssertEqual(revocations, 0)
        XCTAssertEqual(fixture.keychain.events, ["update"])
        fixture.keychain.beforeWalletRead = nil
        XCTAssertTrue(try fixture.persistedWallet().accounts.contains { $0.previewAccountKey == added.previewAccountKey })
        fixture.keychain.beforeWalletRead = { _ in XCTAssertTrue(insideTransaction) }

        let imported = try await manager.addWallet(input: WalletCrypto.hexString(data: Vectors.onePrivateKey), inputPassword: nil)
        fixture.keychain.beforeWalletRead = nil
        fixture.keychain.beforeWalletWrite = nil

        XCTAssertEqual(transactionEntries, 2)
        XCTAssertEqual(revocations, 0)
        XCTAssertEqual(fixture.keychain.events, ["update", "delete", "add"])
        XCTAssertNotNil(fixture.keychain.walletData[imported.id])
    }

    func testCleanupFailureLeavesSourceAndMetadataUnchanged() async throws {
        for operation in RemovalOperation.allCases {
            let fixture = try RemovalFixture()
            var cleanupAttempts = 0
            let manager = fixture.manager { _ in
                cleanupAttempts += 1
                throw TestError.cleanupFailed
            }
            XCTAssertTrue(manager.reloadFromStore())
            let wallet = try XCTUnwrap(manager.wallets.first { $0.id == fixture.walletID })
            let originalData = fixture.keychain.walletData
            let originalAccounts = wallet.accounts
            let account = wallet.accounts[1]
            WalletsMetadataService.saveAccountName("Still present", wallet: wallet, account: account)
            defer { fixture.clearMetadata() }

            do {
                try await operation.apply(manager: manager, wallet: wallet)
                XCTFail("Cleanup failure must prevent the source mutation")
            } catch TestError.cleanupFailed {
            }

            XCTAssertEqual(cleanupAttempts, 1)
            XCTAssertTrue(fixture.keychain.events.isEmpty)
            XCTAssertEqual(fixture.keychain.walletData, originalData)
            XCTAssertEqual(manager.wallets.first { $0.id == wallet.id }?.accounts, originalAccounts)
            XCTAssertEqual(WalletsMetadataService.getAccountName(walletId: wallet.id, account: account), "Still present")
        }
    }

    func testSourceWriteFailureKeepsCleanupAppliedWithoutDeletingMetadata() async throws {
        for operation in RemovalOperation.allCases {
            let fixture = try RemovalFixture()
            fixture.keychain.deleteStatus = errSecInteractionNotAllowed
            fixture.keychain.updateStatus = errSecInteractionNotAllowed
            var cleanupApplied = false
            let manager = fixture.manager { _ in
                cleanupApplied = true
                fixture.keychain.events.append("cleanup")
            }
            XCTAssertTrue(manager.reloadFromStore())
            let wallet = try XCTUnwrap(manager.wallets.first { $0.id == fixture.walletID })
            let originalData = fixture.keychain.walletData
            let originalAccounts = wallet.accounts
            let account = wallet.accounts[1]
            WalletsMetadataService.saveAccountName("Still present", wallet: wallet, account: account)
            defer { fixture.clearMetadata() }

            do {
                try await operation.apply(manager: manager, wallet: wallet)
                XCTFail("Expected the source write failure")
            } catch is Keychain.KeychainError {
            }

            XCTAssertTrue(cleanupApplied)
            XCTAssertEqual(fixture.keychain.events, ["cleanup", operation == .wallet ? "delete" : "update"])
            XCTAssertEqual(fixture.keychain.walletData, originalData)
            XCTAssertEqual(manager.wallets.first { $0.id == wallet.id }?.accounts, originalAccounts)
            XCTAssertEqual(WalletsMetadataService.getAccountName(walletId: wallet.id, account: account), "Still present")
        }
    }

    func testDeletingAndReimportingTheSameKeyRequiresFreshSiteApproval() async throws {
        let fixture = try RemovalFixture()
        let key = try XCTUnwrap(WalletStoredKey.importPrivateKey(
            privateKey: Vectors.onePrivateKey, name: "", password: Vectors.walletCoreJSONMnemonicPassword,
            coin: .ethereum
        ))
        fixture.keychain.walletData[fixture.walletID] = try XCTUnwrap(key.exportJSON())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wallet-removal-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
            fixture.clearMetadata()
        }
        let store = ExtensionRequestFileStore(rootURL: directory, directoryBoundary: directory)
        let manager = fixture.transactionManager(store)
        XCTAssertTrue(manager.reloadFromStore())
        let wallet = try XCTUnwrap(manager.wallets.first { $0.id == fixture.walletID })
        let account = try XCTUnwrap(wallet.accounts.first)
        let descriptor = WalletAccountDescriptor(walletID: wallet.id, account: account)
        let origin = "https://wallet-removal.example"

        try grant(descriptor, in: store, id: 1, origin: origin)
        guard case .snapshot(let granted) = store.configurationSnapshot(configurationKey: origin, profileIdentifier: nil) else {
            return XCTFail("Expected the original grant")
        }
        XCTAssertEqual(granted.ethereumAccount, descriptor)

        try await manager.delete(wallet: wallet)
        let reimported = try await manager.addWallet(input: WalletCrypto.hexString(data: Vectors.onePrivateKey), inputPassword: nil)

        XCTAssertNotEqual(reimported.id, wallet.id)
        XCTAssertEqual(reimported.accounts.first?.address.lowercased(), descriptor.normalizedAddress)
        guard case .snapshot(let removed) = store.configurationSnapshot(configurationKey: origin, profileIdentifier: nil) else {
            return XCTFail("Expected the disconnected snapshot")
        }
        XCTAssertNil(removed.ethereumAccount)
        XCTAssertGreaterThan(removed.version.revisions.ethereum, granted.version.revisions.ethereum)
        let retry = try connection(in: store, id: 2, origin: origin)
        let retryRequest = try XCTUnwrap(retry.request)
        XCTAssertNil(retryRequest.authorizedAccount)
        XCTAssertNil(DappRequestProcessor().prepareWithoutWallets(retryRequest))
        let catalog = try XCTUnwrap(manager.reviewCatalog())
        guard case .approval(.selectAccount) = DappRequestProcessor().prepare(retryRequest, catalog: catalog) else {
            return XCTFail("Reimported keys require a fresh site approval")
        }
        XCTAssertTrue(catalog.orderedAccounts.contains { $0.walletId == reimported.id })
    }

    private func connection(in store: ExtensionRequestFileStore, id: Int, origin: String) throws -> ExtensionBridge.Snapshot {
        guard case .snapshot(let authority) = store.configurationSnapshot(configurationKey: origin, profileIdentifier: nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        let host = try XCTUnwrap(URL(string: origin)?.host)
        let raw: [String: Any] = [
            "id": id, "name": "requestAccounts", "provider": "ethereum",
            "host": host, "configurationKey": origin,
            "enqueueAttempt": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "admissionDeadline": Int(Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000),
            "workflowVersion": ExtensionBridge.workflowVersion,
            "authority": authority.version.json,
            "body": ["address": "", "chainId": "0x1"],
        ]
        let request = try XCTUnwrap(SafariRequest(json: raw))
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(request: request, rawObject: raw),
              case .accepted(let handle, _, _, _, _) = store.enqueue(ingress: ingress, profileIdentifier: nil),
              case .found(let snapshot) = store.load(handle: handle) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return snapshot
    }

    private func grant(_ account: WalletAccountDescriptor, in store: ExtensionRequestFileStore, id: Int, origin: String) throws {
        let initial = try connection(in: store, id: id, origin: origin)
        let request = try XCTUnwrap(initial.request)
        guard case .claimed(let claim) = store.claim(handle: initial.handle),
              case .began(let permit) = store.begin(claim: claim) else { throw CocoaError(.fileWriteUnknown) }
        let response = ResponseToExtension(
            for: request, payload: .result(.strings([account.normalizedAddress])),
            mutation: .accounts([.ethereum(address: account.normalizedAddress, chainId: "0x1")]),
            approvedAccounts: [account]
        ).markingApprovalCommitted()
        guard store.complete(permit: permit, response: response, authority: .ordinary) == .persisted else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private enum RemovalOperation: CaseIterable {
        case wallet, accounts, enabledAccounts

        @MainActor
        func apply(manager: WalletsManager, wallet: WalletContainer) async throws {
            switch self {
            case .wallet:
                try await manager.delete(wallet: wallet)
            case .accounts:
                try await manager.update(wallet: wallet, removeAccounts: [wallet.accounts[1]])
            case .enabledAccounts:
                try await manager.update(wallet: wallet, enabledAccounts: [wallet.accounts[0]])
            }
        }
    }

    private final class RemovalFixture {
        let walletID = "removal-test-\(UUID().uuidString)"
        let siblingID = "removal-sibling-\(UUID().uuidString)"
        let keychain = WalletRemovalKeychainStub()

        init() throws {
            let data = try walletData()
            keychain.walletData = [walletID: data, siblingID: data]
        }

        func manager(onRevoke: @escaping (WalletAuthorityRemoval) throws -> Void) -> WalletsManager {
            transactionManager(WalletSourceMutationStub(onRevoke: onRevoke))
        }

        func transactionManager(_ mutator: any WalletSourceMutating) -> WalletsManager {
            WalletsManager(
                keychain: Keychain(copyMatching: keychain.copyMatching, add: keychain.add,
                                   update: keychain.update, delete: keychain.delete),
                walletSourceMutator: mutator
            )
        }

        func walletData(adding account: WalletAccount? = nil) throws -> Data {
            let key = try XCTUnwrap(WalletStoredKey.importJSON(json: Vectors.walletCoreJSONMnemonicFixture))
            for account in [additionalAccount(index: 1)] + (account.map { [$0] } ?? []) {
                key.addAccountDerivation(
                    address: account.address, coin: account.coin, derivation: account.derivation,
                    derivationPath: account.derivationPath, publicKey: account.publicKey,
                    extendedPublicKey: account.extendedPublicKey
                )
            }
            return try XCTUnwrap(key.exportJSON())
        }

        func additionalAccount(index: Int) -> WalletAccount {
            WalletAccount(
                address: index == 1 ? Vectors.oneEthereumAddress : Vectors.sequentialEthereumAddress,
                coin: .ethereum, derivation: .custom, derivationPath: "m/44'/60'/0'/0/\(index)",
                publicKey: "", extendedPublicKey: ""
            )
        }

        func persistedWallet() throws -> WalletContainer {
            let data = try XCTUnwrap(keychain.walletData[walletID])
            let key = try XCTUnwrap(WalletStoredKey.importJSON(json: data))
            return WalletContainer(id: walletID, key: key)
        }

        func clearMetadata() {
            for id in [walletID, siblingID] {
                guard let key = WalletStoredKey.importJSON(json: Vectors.walletCoreJSONMnemonicFixture) else { continue }
                WalletsMetadataService.removeMetadataForWallet(WalletContainer(id: id, key: key), postChange: false)
            }
        }
    }
}

private final class WalletRemovalKeychainStub {
    private let walletPrefix = "org.lil.wallet.wallet."
    var walletData = [String: Data]()
    var events = [String]()
    var deleteStatus = errSecSuccess
    var updateStatus = errSecSuccess
    var beforeWalletRead: ((String) -> Void)?
    var beforeWalletWrite: (() -> Void)?

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let query = query as NSDictionary
        if query[kSecReturnAttributes as String] as? Bool == true {
            result?.pointee = walletData.keys.sorted().map {
                [kSecAttrAccount as String: walletPrefix + $0]
            } as CFArray
            return errSecSuccess
        }
        guard let key = query[kSecAttrAccount as String] as? String else { return errSecItemNotFound }
        if key == "org.lil.wallet.password" {
            result?.pointee = Vectors.walletCoreJSONMnemonicPassword as CFData
            return errSecSuccess
        }
        guard key.hasPrefix(walletPrefix) else { return errSecItemNotFound }
        let id = String(key.dropFirst(walletPrefix.count))
        beforeWalletRead?(id)
        guard let data = walletData[id] else {
            return errSecItemNotFound
        }
        result?.pointee = data as CFData
        return errSecSuccess
    }

    func add(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let attributes = attributes as NSDictionary
        guard let key = attributes[kSecAttrAccount as String] as? String,
              key.hasPrefix(walletPrefix), let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }
        events.append("add")
        beforeWalletWrite?()
        walletData[String(key.dropFirst(walletPrefix.count))] = data
        return errSecSuccess
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        events.append("update")
        beforeWalletWrite?()
        guard updateStatus == errSecSuccess else { return updateStatus }
        let query = query as NSDictionary
        let attributes = attributes as NSDictionary
        guard let key = query[kSecAttrAccount as String] as? String,
              key.hasPrefix(walletPrefix), let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }
        let id = String(key.dropFirst(walletPrefix.count))
        guard walletData[id] != nil else { return errSecItemNotFound }
        walletData[id] = data
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        events.append("delete")
        beforeWalletWrite?()
        guard deleteStatus == errSecSuccess else { return deleteStatus }
        let query = query as NSDictionary
        guard let key = query[kSecAttrAccount as String] as? String, key.hasPrefix(walletPrefix) else { return errSecParam }
        return walletData.removeValue(forKey: String(key.dropFirst(walletPrefix.count))) == nil ? errSecItemNotFound : errSecSuccess
    }
}
#endif

@MainActor
final class WalletSigningScopeTests: XCTestCase {

    private let walletID = "approved-wallet"

    func testAccessRejectsOtherIdentitiesWithoutConsumingBinding() async throws {
        let approved = descriptor()
        let backing = SigningSpy()
        let access = requestAccess(approved: approved, backing: backing)
        let alternatives = [
            WalletAccountDescriptor(walletID: "other-wallet", account: approved.account),
            descriptor(address: Vectors.oneEthereumAddress),
            descriptor(path: "m/44'/60'/0'/0/1"),
            WalletAccountDescriptor(walletID: walletID, account: solanaAccount()),
        ]
        for alternative in alternatives {
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: alternative)
            XCTAssertFalse(access.bind(operation: operation, authorityIsCurrent: { _ in true }))
            XCTAssertTrue(backing.operations.isEmpty)
        }

        let operation = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
        let signer = access
        XCTAssertTrue(access.bind(operation: operation, authorityIsCurrent: { _ in true }))
        let result = await signer.sign()
        guard case .success(.ethereumSignature("test-signature")) = result else {
            return XCTFail("Expected the approved operation to sign")
        }
        XCTAssertEqual(backing.operations.map(\.approvedAccount), [approved])
        XCTAssertEqual(backing.operations.first?.handle, operation.handle)
        XCTAssertEqual(backing.operations.first?.deadline, operation.deadline)
    }

    func testAccountIdentityNormalizesEthereumCaseAndIgnoresPublicMetadata() throws {
        let approved = descriptor()
        let reconstructed = WalletAccount(
            address: approved.account.address.uppercased(),
            coin: .ethereum,
            derivation: .default,
            derivationPath: approved.derivationPath,
            publicKey: "different-public-metadata",
            extendedPublicKey: "different-extended-metadata"
        )
        let access = requestAccess(approved: approved, backing: SigningSpy())
        let operation = try approvedWalletSigningOperationForTesting(
            approvedAccount: WalletAccountDescriptor(walletID: walletID, account: reconstructed)
        )
        XCTAssertTrue(access.bind(operation: operation, authorityIsCurrent: { _ in true }))
    }

    func testBindingPreservesSolanaAddressCase() throws {
        let account = solanaAccount()
        let approved = WalletAccountDescriptor(walletID: walletID, account: account)
        let access = requestAccess(approved: approved, backing: SigningSpy())
        let changed = WalletAccountDescriptor(
            walletID: walletID,
            coin: .solana,
            normalizedAddress: account.address.replacingOccurrences(of: "C", with: "c"),
            derivationPath: account.derivationPath
        )
        XCTAssertTrue(changed.isValid)
        XCTAssertFalse(access.bind(operation: try approvedWalletSigningOperationForTesting(approvedAccount: changed), authorityIsCurrent: { _ in true }))
        XCTAssertTrue(access.bind(operation: try approvedWalletSigningOperationForTesting(approvedAccount: approved), authorityIsCurrent: { _ in true }))
    }

    func testAccessAndSignerAreSingleUseAfterSuccessAndFailure() async throws {
        for succeeds in [false, true] {
            let backing = SigningSpy()
            backing.result = succeeds ? .success(.ethereumSignature("test-signature")) : .failure(.failedToSign)
            let access = requestAccess(approved: descriptor(), backing: backing)
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: descriptor())
            let signer = access
            XCTAssertTrue(access.bind(operation: operation, authorityIsCurrent: { _ in true }))
            XCTAssertFalse(access.bind(operation: operation, authorityIsCurrent: { _ in true }))
            _ = await signer.sign()
            assertUnavailable(await signer.sign())
            XCTAssertFalse(access.bind(operation: operation, authorityIsCurrent: { _ in true }))
            XCTAssertEqual(backing.operations.count, 1)
            XCTAssertEqual(backing.invalidations, 1)
        }
    }

    func testOwnerInvalidationBeforeSigningReleasesAuthorization() async throws {
        for invalidateAccess in [false, true] {
            let backing = SigningSpy()
            let access = requestAccess(approved: descriptor(), backing: backing)
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: descriptor())
            let signer = access
            XCTAssertTrue(access.bind(operation: operation, authorityIsCurrent: { _ in true }))
            if invalidateAccess {
                access.invalidate()
            } else {
                signer.invalidate()
            }
            XCTAssertEqual(backing.invalidations, 1)
            assertUnavailable(await signer.sign())
            assertUnavailable(await signer.sign())
            XCTAssertTrue(backing.operations.isEmpty)
            XCTAssertFalse(access.bind(operation: operation, authorityIsCurrent: { _ in true }))
            XCTAssertEqual(backing.invalidations, 1)
        }
    }

    func testConcurrentSigningConsumesAuthorizationBeforeSuspension() async throws {
        let backing = SigningSpy()
        let started = expectation(description: "Signing started")
        var continuation: CheckedContinuation<Void, Never>?
        backing.beforeReturn = {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        let access = requestAccess(approved: descriptor(), backing: backing)
        let signer = access
        XCTAssertTrue(access.bind(operation: try approvedWalletSigningOperationForTesting(approvedAccount: descriptor()), authorityIsCurrent: { _ in true }))
        let first = Task { await signer.sign() }
        await fulfillment(of: [started], timeout: 1)
        assertUnavailable(await signer.sign())
        XCTAssertEqual(backing.operations.count, 1)
        try XCTUnwrap(continuation).resume()
        _ = await first.value
    }

    func testConcurrentSigningCannotReuseAuthorizationDuringEitherAuthorityCheck() async throws {
        for suspendedCheck in 1...2 {
            let backing = SigningSpy()
            let access = requestAccess(approved: descriptor(), backing: backing)
            let checking = expectation(description: "Authority check \(suspendedCheck) started")
            var checks = 0
            var continuation: CheckedContinuation<Bool, Never>?
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: descriptor())
            let signer = access
            XCTAssertTrue(access.bind(operation: operation, authorityIsCurrent: { handle in
                XCTAssertEqual(handle, operation.handle)
                checks += 1
                guard checks == suspendedCheck else { return true }
                return await withCheckedContinuation {
                    continuation = $0
                    checking.fulfill()
                }
            }))
            let first = Task { await signer.sign() }
            await fulfillment(of: [checking], timeout: 1)
            assertUnavailable(await signer.sign())
            XCTAssertEqual(checks, suspendedCheck)
            XCTAssertEqual(backing.operations.count, suspendedCheck - 1)
            XCTAssertEqual(backing.invalidations, 0)
            try XCTUnwrap(continuation).resume(returning: true)
            guard case .success(.ethereumSignature("test-signature")) = await first.value else {
                return XCTFail("The original signing call must retain its authorization")
            }
            XCTAssertEqual(checks, 2)
            XCTAssertEqual(backing.operations.count, 1)
            XCTAssertEqual(backing.invalidations, 1)
        }
    }

    func testAuthoritySuspensionCannotOutliveAuthorizationBeforeOrAfterSigning() async throws {
        enum Interruption: CaseIterable {
            case revoked, expired, invalidated, canceled, sourceChanged
        }
        for suspendedCheck in 1...2 {
            for interruption in Interruption.allCases {
                let start = Date()
                var now = start
                var current = true
                let backing = SigningSpy()
                let access = requestAccess(
                    approved: descriptor(), backing: backing, deadline: start.addingTimeInterval(1),
                    isCurrent: { current }, clock: { now }
                )
                let checking = expectation(description: "Authority check \(suspendedCheck): \(interruption)")
                var checks = 0
                var continuation: CheckedContinuation<Bool, Never>?
                let operation = try approvedWalletSigningOperationForTesting(
                    approvedAccount: descriptor(), deadline: start.addingTimeInterval(1)
                )
                let signer = access
                XCTAssertTrue(access.bind(operation: operation, authorityIsCurrent: { _ in
                    checks += 1
                    guard checks == suspendedCheck else { return true }
                    return await withCheckedContinuation {
                        continuation = $0
                        checking.fulfill()
                    }
                }))
                let signing = Task { await signer.sign() }
                await fulfillment(of: [checking], timeout: 1)
                switch interruption {
                case .revoked: break
                case .expired: now = start.addingTimeInterval(1)
                case .invalidated: access.invalidate()
                case .canceled: signing.cancel()
                case .sourceChanged: current = false
                }
                if interruption == .invalidated || interruption == .canceled {
                    XCTAssertEqual(backing.invalidations, 1)
                }
                try XCTUnwrap(continuation).resume(returning: interruption != .revoked)
                assertUnavailable(await signing.value)
                assertUnavailable(await signer.sign())
                XCTAssertEqual(checks, suspendedCheck)
                XCTAssertEqual(backing.operations.count, suspendedCheck - 1)
                XCTAssertEqual(backing.invalidations, 1)
                signer.invalidate()
                access.invalidate()
                XCTAssertEqual(backing.invalidations, 1)
            }
        }
    }

    func testExpiryBeforeSigningNeverReachesBacking() async throws {
        let start = Date()
        var now = start
        let backing = SigningSpy()
        let access = requestAccess(approved: descriptor(), backing: backing, deadline: start.addingTimeInterval(1), clock: { now })
        let signer = access
        XCTAssertTrue(access.bind(operation: try approvedWalletSigningOperationForTesting(
            approvedAccount: descriptor(), deadline: start.addingTimeInterval(1)
        ), authorityIsCurrent: { _ in true }))
        now = start.addingTimeInterval(1)
        assertUnavailable(await signer.sign())
        now = start
        assertUnavailable(await signer.sign())
        XCTAssertTrue(backing.operations.isEmpty)
    }

    func testCancellationBeforeSigningConsumesAuthorizationWithoutBackingAccess() async throws {
        let backing = SigningSpy()
        let access = requestAccess(approved: descriptor(), backing: backing)
        let signer = access
        XCTAssertTrue(access.bind(operation: try approvedWalletSigningOperationForTesting(approvedAccount: descriptor()), authorityIsCurrent: { _ in true }))
        let task = Task { await signer.sign() }
        task.cancel()
        assertUnavailable(await task.value)
        assertUnavailable(await signer.sign())
        XCTAssertTrue(backing.operations.isEmpty)
    }

    func testInvalidationExpiryAndCancellationDiscardInFlightResults() async throws {
        for interruption in 0..<4 {
            let start = Date()
            var now = start
            var current = true
            let backing = SigningSpy()
            let started = expectation(description: "Signing started")
            var continuation: CheckedContinuation<Void, Never>?
            backing.beforeReturn = {
                await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
            let access = requestAccess(
                approved: descriptor(), backing: backing, deadline: start.addingTimeInterval(1),
                isCurrent: { current }, clock: { now }
            )
            let signer = access
            XCTAssertTrue(access.bind(operation: try approvedWalletSigningOperationForTesting(
                approvedAccount: descriptor(), deadline: start.addingTimeInterval(1)
            ), authorityIsCurrent: { _ in true }))
            let signing = Task { await signer.sign() }
            await fulfillment(of: [started], timeout: 1)
            switch interruption {
            case 0: access.invalidate()
            case 1: now = start.addingTimeInterval(1)
            case 2: signing.cancel()
            default: current = false
            }
            if interruption == 0 || interruption == 2 {
                XCTAssertEqual(backing.invalidations, 1)
            }
            try XCTUnwrap(continuation).resume()
            assertUnavailable(await signing.value)
            assertUnavailable(await signer.sign())
            XCTAssertEqual(backing.operations.count, 1)
        }
    }

    func testSigningConsumptionDoesNotConsumeExecutionLease() async throws {
        let backing = SigningSpy()
        let access = requestAccess(approved: descriptor(), backing: backing)
        let signer = access
        XCTAssertTrue(access.bind(operation: try approvedWalletSigningOperationForTesting(approvedAccount: descriptor()), authorityIsCurrent: { _ in true }))
        _ = await signer.sign()
        let firstLease = await access.takeCommitLease()
        XCTAssertNotNil(firstLease)
        firstLease?.release()
        let secondLease = await access.takeCommitLease()
        XCTAssertNil(secondLease)
        assertUnavailable(await signer.sign())
    }

    func testStaleAndInvalidScopesCannotBind() throws {
        let operation = try approvedWalletSigningOperationForTesting(approvedAccount: descriptor())
        for approved in [
            WalletAccountDescriptor(walletID: "", account: descriptor().account),
            descriptor(address: "0x1234"),
            descriptor(path: ""),
        ] {
            let backing = SigningSpy()
            let access = requestAccess(approved: approved, backing: backing)
            XCTAssertFalse(access.bind(operation: operation, authorityIsCurrent: { _ in true }))
            XCTAssertTrue(backing.operations.isEmpty)
        }
        let backing = SigningSpy()
        let stale = requestAccess(approved: descriptor(), backing: backing, isCurrent: { false })
        XCTAssertFalse(stale.bind(operation: operation, authorityIsCurrent: { _ in true }))
        XCTAssertTrue(backing.operations.isEmpty)
    }

    func testSourceSignerSignsOnceAndReturnsVerifiableSignature() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: walletID)]
        reader.walletData = [walletID: Vectors.walletCoreJSONPrivateKeyFixture]
        reader.passwordData = Vectors.walletCoreJSONPrivateKeyPassword
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        XCTAssertTrue(manager.reloadFromStore())
        let account = try XCTUnwrap(manager.wallets.first?.accounts.first)
        let operation = try approvedWalletSigningOperationForTesting(
            approvedAccount: WalletAccountDescriptor(walletID: walletID, account: account)
        )
        let signer = WalletSigningSession.fromSource(operation: operation, walletsManager: manager, authorityIsCurrent: { _ in true })
        try assertWalletSigningSuccessForTesting(await signer.sign(), account: account)
        assertUnavailable(await signer.sign())
        XCTAssertEqual(reader.passwordReadCount, 1)
    }

    func testSourceSignerRejectsMissingAccountAndExpiredOperation() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.passwordData = Vectors.walletCoreJSONPrivateKeyPassword
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        let start = Date()
        let operation = try approvedWalletSigningOperationForTesting(approvedAccount: descriptor(), deadline: start)
        let expired = WalletSigningSession.fromSource(operation: operation, walletsManager: manager, authorityIsCurrent: { _ in true }, clock: { start })
        assertUnavailable(await expired.sign())
        let missing = WalletSigningSession.fromSource(
            operation: try approvedWalletSigningOperationForTesting(approvedAccount: descriptor()), walletsManager: manager, authorityIsCurrent: { _ in true }
        )
        assertUnavailable(await missing.sign())
        XCTAssertEqual(reader.passwordReadCount, 0)
    }

    func testSigningOperationRequiresPayloadCoinAndBroadcastClusterToMatchApproval() throws {
        let solana = WalletAccountDescriptor(walletID: walletID, account: solanaAccount())
        let publicKey = try XCTUnwrap(WalletCrypto.base58Decode(string: solana.normalizedAddress))
        let message = SolanaMessageFixture.wireMessage(
            accountKeys: [publicKey], bodyAfterBlockhash: Data.encodeLength(0)
        )
        let encodedMessage = WalletCrypto.base58Encode(data: message)
        let transaction = try Solana.shared.preparedTransactionMessageForSigning(
            message: encodedMessage, publicKey: solana.normalizedAddress
        ).get()
        let legacy = try Solana.shared.preparedLegacySignAndSendTransaction(
            message: encodedMessage, publicKey: solana.normalizedAddress
        ).get()
        let serialized = try Solana.shared.preparedSerializedTransactionForSignAndSend(
            serializedTransaction: WalletCrypto.base58Encode(data: Data([1]) + Data(repeating: 0, count: 64) + message),
            publicKey: solana.normalizedAddress
        ).get()
        let options = try Solana.preparedSendOptions(from: [:]).get()
        let cases: [(SignMessageAction.Payload, WalletCoin, Bool)] = [
            (.ethereumMessage(Vectors.ethereumRawSignDigest), .ethereum, false),
            (.ethereumPersonalMessage(walletSigningTestMessage), .ethereum, false),
            (.ethereumTypedData(Vectors.typedDataJSON), .ethereum, false),
            (.solanaMessage(walletSigningTestMessage), .solana, false),
            (.solanaTransaction(transaction), .solana, false),
            (.solanaTransactions([transaction]), .solana, false),
            (.solanaLegacyBroadcast(legacy, options), .solana, true),
            (.solanaSerializedBroadcast(serialized, options), .solana, true),
        ]
        for approved in [descriptor(), solana] {
            var request = try XCTUnwrap(SafariRequest(json: [
                "id": 1, "name": "signMessage", "provider": approved.coin == .ethereum ? "ethereum" : "solana",
                "host": "wallet.example", "configurationKey": "https://wallet.example",
                "enqueueAttempt": String(repeating: "a", count: 32),
                "admissionDeadline": Int(Date().addingTimeInterval(120).timeIntervalSince1970 * 1_000),
                "workflowVersion": ExtensionBridge.workflowVersion,
                "body": approved.coin == .ethereum
                    ? ["address": approved.normalizedAddress, "chainId": "0x1"]
                    : ["publicKey": approved.normalizedAddress],
            ]))
            request.authorizedAccount = approved
            for (payload, coin, requiresCluster) in cases {
                for cluster: Solana.Cluster? in [nil, .devnet] {
                    let action = SignMessageAction(
                        subject: .signMessage, walletId: approved.walletID,
                        account: approved.account, meta: "", payload: payload
                    )
                    let operation = ApprovedWalletSigningOperation(
                        request: request, approval: .message(action, cluster),
                        authorization: walletSigningAuthorizationForTesting(approvedAccount: approved)
                    )
                    XCTAssertEqual(operation != nil, approved.coin == coin && requiresCluster == (cluster != nil))
                }
            }
        }
    }

    func testEthereumSigningModesUseTheCapturedPayload() async throws {
        let cases: [(SignMessageAction.Payload, String)] = [
            (.ethereumMessage(Vectors.ethereumRawSignDigest), Vectors.ethereumRawSignature),
            (.ethereumPersonalMessage(Vectors.ethereumPersonalMessage), Vectors.ethereumPersonalMessageSignature),
            (.ethereumTypedData(Vectors.typedDataJSON), Vectors.ethereumTypedDataSignature),
        ]
        for (payload, expectedSignature) in cases {
            let (account, access) = try unlockedSigningAccess(coin: .ethereum, key: Vectors.ethereumSignerPrivateKey)
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: account, payload: payload)
            let signer = WalletSigningSession(access, authorization: operation.authorization, isCurrent: { true })
            XCTAssertTrue(signer.bind(operation: operation, authorityIsCurrent: { _ in true }))
            guard case .success(.ethereumSignature(let signature)) = await signer.sign() else {
                return XCTFail("Expected the approved Ethereum signing mode")
            }
            XCTAssertEqual(signature, expectedSignature)
            assertUnavailable(await signer.sign())
        }
    }

    func testCryptographicFailureConsumesTheBoundSigner() async throws {
        let (account, access) = try unlockedSigningAccess(coin: .ethereum, key: Vectors.ethereumSignerPrivateKey)
        let operation = try approvedWalletSigningOperationForTesting(
            approvedAccount: account, payload: .ethereumTypedData(Vectors.malformedTypedDataJSON)
        )
        let signer = WalletSigningSession(access, authorization: operation.authorization, isCurrent: { true })
        XCTAssertTrue(signer.bind(operation: operation, authorityIsCurrent: { _ in true }))
        guard case .failure(.failedToSign) = await signer.sign() else {
            return XCTFail("Expected malformed typed data to fail")
        }
        assertUnavailable(await signer.sign())
    }

    func testEthereumTransactionCapturesFinalNonceFeesAndDestination() async throws {
        let cases: [(PreparedTransactionFee, PreparedTransactionFee)] = [
            (.legacy(gasPrice: 10), .legacy(gasPrice: 20)),
            (.eip1559(maxPriorityFeePerGas: 2, maxFeePerGas: 10),
             .eip1559(maxPriorityFeePerGas: 3, maxFeePerGas: 20)),
        ]
        for (initialFee, finalFee) in cases {
            let (account, access) = try unlockedSigningAccess(coin: .ethereum, key: Vectors.ethereumSignerPrivateKey)
            let network = ResolvedEthereumNetwork(network: EthereumNetwork(
                chainId: 10, name: "Approved network", symbol: "ETH",
                rpcEndpoint: .unauthenticated(URL(string: "https://approved.example/rpc")!),
                isTestnet: true, mightShowPrice: false, explorer: nil
            ), source: .custom)
            let original = Transaction(
                id: UUID(), from: account.normalizedAddress,
                to: "0x0000000000000000000000000000000000000002",
                nonce: "0x0", gas: "0x5208", value: "0x1", data: "0x",
                feeIntent: initialFee.intent, preparedFee: initialFee
            )
            var final = original
            final.nonce = "0x7"
            final.preparedFee = finalFee
            var request = try XCTUnwrap(SafariRequest(json: [
                "id": 1, "name": "signTransaction", "provider": "ethereum",
                "host": "wallet.example", "configurationKey": "https://wallet.example",
                "enqueueAttempt": String(repeating: "a", count: 32),
                "admissionDeadline": Int(Date().addingTimeInterval(120).timeIntervalSince1970 * 1_000),
                "workflowVersion": ExtensionBridge.workflowVersion,
                "body": ["address": account.normalizedAddress, "chainId": "0xa"],
            ]))
            request.authorizedAccount = account
            let operation = try XCTUnwrap(ApprovedWalletSigningOperation(
                request: request,
                approval: .transaction(SendTransactionAction(
                    transaction: original, resolvedNetwork: network, walletId: account.walletID, account: account.account
                ), final),
                authorization: walletSigningAuthorizationForTesting(approvedAccount: account)
            ))
            let expected = try Ethereum.signedTransaction(
                transaction: final, privateKey: XCTUnwrap(WalletPrivateKey(data: Vectors.ethereumSignerPrivateKey)),
                network: network.network
            ).get()
            final.nonce = "0x8"
            let signer = WalletSigningSession(access, authorization: operation.authorization, isCurrent: { true })
            XCTAssertTrue(signer.bind(operation: operation, authorityIsCurrent: { _ in true }))
            guard case .success(.ethereumTransaction(let signed, let hash, let destination)) = await signer.sign() else {
                return XCTFail("Expected signed Ethereum transaction")
            }
            XCTAssertEqual(signed, expected)
            XCTAssertEqual(hash, Ethereum.transactionHash(signedTransaction: expected))
            XCTAssertEqual(destination, network)
            assertUnavailable(await signer.sign())
            if finalFee.isEIP1559 { XCTAssertTrue(signed.hasPrefix("0x02")) }
        }
    }

    func testSolanaMessageTransactionAndBatchSignaturesPreserveOrder() async throws {
        let publicKeyData = try XCTUnwrap(WalletCrypto.base58Decode(string: Vectors.solanaPreparedSignerPublicKey))
        let messages = [UInt8(9), UInt8(10)].map { seed in
            SolanaMessageFixture.wireMessage(accountKeys: [publicKeyData], blockhashSeed: seed,
                                            bodyAfterBlockhash: Data.encodeLength(0))
        }
        let prepared = try messages.map {
            try Solana.shared.preparedTransactionMessageForSigning(
                message: WalletCrypto.base58Encode(data: $0), publicKey: Vectors.solanaPreparedSignerPublicKey
            ).get()
        }
        let cases: [(SignMessageAction.Payload, [Data])] = [
            (.solanaMessage(walletSigningTestMessage), [walletSigningTestMessage]),
            (.solanaTransaction(prepared[0]), [messages[0]]),
            (.solanaTransactions(prepared), messages),
        ]
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        for (payload, expectedMessages) in cases {
            let (account, access) = try unlockedSigningAccess(coin: .solana, key: Vectors.solanaPreparedSignerPrivateKey)
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: account, payload: payload)
            let signer = WalletSigningSession(access, authorization: operation.authorization, isCurrent: { true })
            XCTAssertTrue(signer.bind(operation: operation, authorityIsCurrent: { _ in true }))
            let signatures: [String]
            switch try await signer.sign().get() {
            case .solanaSignature(let value): signatures = [value]
            case .solanaSignatures(let values): signatures = values
            default: return XCTFail("Expected Solana signatures")
            }
            XCTAssertEqual(signatures.count, expectedMessages.count)
            for (signature, message) in zip(signatures, expectedMessages) {
                let bytes = try XCTUnwrap(WalletCrypto.base58Decode(string: signature))
                XCTAssertTrue(publicKey.isValidSignature(bytes, for: message))
            }
            assertUnavailable(await signer.sign())
        }
    }

    func testMalformedSolanaBatchCannotProducePartialApproval() throws {
        let account = WalletAccountDescriptor(walletID: walletID, account: solanaAccount())
        let publicKey = try XCTUnwrap(WalletCrypto.base58Decode(string: account.normalizedAddress))
        let message = WalletCrypto.base58Encode(data: SolanaMessageFixture.wireMessage(
            accountKeys: [publicKey], bodyAfterBlockhash: Data.encodeLength(0)
        ))
        let catalog = WalletReviewCatalog(
            identity: .init(generation: nil, catalogData: try WalletAccountCatalog(accounts: [account]).canonicalData()),
            orderedAccounts: [account.specificAccount]
        )
        for messages in [[message, "0"], ["0", message]] {
            let request = try XCTUnwrap(SafariRequest(json: [
                "id": 2, "name": "signAllTransactions", "provider": "solana",
                "host": "wallet.example", "configurationKey": "https://wallet.example",
                "enqueueAttempt": String(repeating: "a", count: 32),
                "admissionDeadline": Int(Date().addingTimeInterval(120).timeIntervalSince1970 * 1_000),
                "workflowVersion": ExtensionBridge.workflowVersion,
                "body": ["publicKey": account.normalizedAddress, "object": ["params": ["messages": messages]]],
            ]))
            guard case .response(let response) = DappRequestProcessor().prepare(request, catalog: catalog) else {
                return XCTFail("A malformed batch must not issue a partial signing approval")
            }
            XCTAssertNotNil(response.json["error"])
            XCTAssertNil(response.json["result"])
        }
    }

    func testSolanaBroadcastPreservesCosignersPlacementClusterAndOptions() async throws {
        let signerPublicKey = try XCTUnwrap(WalletCrypto.base58Decode(string: Vectors.solanaPreparedSignerPublicKey))
        let cosigner = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 5, count: 32))
        let singleMessage = SolanaMessageFixture.wireMessage(accountKeys: [signerPublicKey], bodyAfterBlockhash: Data.encodeLength(0))
        let multiMessage = SolanaMessageFixture.wireMessage(
            requiredSignatures: 2, accountKeys: [cosigner.publicKey.rawRepresentation, signerPublicKey],
            bodyAfterBlockhash: Data.encodeLength(0)
        )
        let cosignerSignature = try cosigner.signature(for: multiMessage)
        let serialized = Data([2]) + cosignerSignature + Data(repeating: 0, count: 64) + multiMessage
        let legacy = try Solana.shared.preparedLegacySignAndSendTransaction(
            message: WalletCrypto.base58Encode(data: singleMessage), publicKey: Vectors.solanaPreparedSignerPublicKey
        ).get()
        let prepared = try Solana.shared.preparedSerializedTransactionForSignAndSend(
            serializedTransaction: WalletCrypto.base58Encode(data: serialized), publicKey: Vectors.solanaPreparedSignerPublicKey
        ).get()
        let options = try Solana.preparedSendOptions(from: [
            "maxRetries": 4, "minContextSlot": 42, "preflightCommitment": "confirmed"
        ]).get()
        let cases: [(SignMessageAction.Payload, Data, Int)] = [
            (.solanaLegacyBroadcast(legacy, options), singleMessage, 0),
            (.solanaSerializedBroadcast(prepared, options), multiMessage, 1),
        ]
        for (payload, message, signerIndex) in cases {
            let (account, access) = try unlockedSigningAccess(coin: .solana, key: Vectors.solanaPreparedSignerPrivateKey)
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: account, payload: payload)
            let signer = WalletSigningSession(access, authorization: operation.authorization, isCurrent: { true })
            XCTAssertTrue(signer.bind(operation: operation, authorityIsCurrent: { _ in true }))
            guard case .success(.solanaTransaction(let signed, let signature, let cluster, let capturedOptions)) = await signer.sign() else {
                return XCTFail("Expected signed Solana transaction")
            }
            let bytes = try XCTUnwrap(Data(base64Encoded: signed))
            let signatureOffset = 1 + signerIndex * 64
            let signerSignature = bytes.subdata(in: signatureOffset..<(signatureOffset + 64))
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: signerPublicKey)
            XCTAssertTrue(publicKey.isValidSignature(signerSignature, for: message))
            XCTAssertEqual(bytes.suffix(message.count), message)
            if signerIndex == 1 {
                XCTAssertEqual(bytes.subdata(in: 1..<65), cosignerSignature)
                XCTAssertEqual(signature, WalletCrypto.base58Encode(data: cosignerSignature))
            } else {
                XCTAssertEqual(signature, WalletCrypto.base58Encode(data: signerSignature))
            }
            XCTAssertEqual(cluster, .devnet)
            XCTAssertEqual(capturedOptions.maxRetries, 4)
            XCTAssertEqual(capturedOptions.minContextSlot, 42)
            XCTAssertEqual(capturedOptions.preflightCommitment, .confirmed)
            assertUnavailable(await signer.sign())
        }
    }

    private func unlockedSigningAccess(coin: WalletCoin, key: Data) throws -> (WalletAccountDescriptor, UnlockedWalletSigner) {
        let password = Data("signing-tests".utf8)
        let storedKey = try XCTUnwrap(WalletStoredKey.importPrivateKey(privateKey: key, name: "Signer", password: password, coin: coin))
        let wallet = WalletContainer(id: walletID, key: storedKey)
        let account = try XCTUnwrap(wallet.accounts.first)
        let access = try XCTUnwrap(UnlockedWalletSigner(password: password, wallets: [wallet]))
        return (WalletAccountDescriptor(walletID: walletID, account: account), access)
    }

    private func descriptor(
        address: String = Vectors.sequentialEthereumAddress,
        path: String = "m/44'/60'/0'/0/0"
    ) -> WalletAccountDescriptor {
        WalletAccountDescriptor(walletID: walletID, coin: .ethereum, normalizedAddress: address.lowercased(), derivationPath: path)
    }

    private func solanaAccount() -> WalletAccount {
        WalletAccount(address: Vectors.sequentialSolanaAddress, coin: .solana, derivation: .solanaSolana,
                      derivationPath: "m/44'/501'/0'/0'", publicKey: Vectors.sequentialSolanaPublicKey, extendedPublicKey: "")
    }

    private func requestAccess(
        approved: WalletAccountDescriptor,
        backing: SigningSpy,
        deadline: Date = .distantFuture,
        isCurrent: @escaping () -> Bool = { true },
        clock: @escaping () -> Date = Date.init
    ) -> WalletSigningSession {
        WalletSigningSession(backing, authorization: walletSigningAuthorizationForTesting(approvedAccount: approved, deadline: deadline), isCurrent: isCurrent,
                                  acquireCommitLease: { WalletExecutionLease {} }, clock: clock)
    }

    private func assertUnavailable(
        _ result: Result<WalletSigningOutput, WalletSigningFailure>,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(.authorizationUnavailable) = result else {
            return XCTFail("Expected unavailable signing authorization", file: file, line: line)
        }
    }

    private final class SigningSpy: OwnedWalletSigningAccess {
        private let lock = NSLock()
        var operations = [ApprovedWalletSigningOperation]()
        private var invalidationCount = 0
        var invalidations: Int { lock.withLock { invalidationCount } }
        var result: Result<WalletSigningOutput, WalletSigningFailure> = .success(.ethereumSignature("test-signature"))
        var beforeReturn: (() async -> Void)?

        @MainActor
        func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
            operations.append(operation)
            await beforeReturn?()
            return result
        }

        func invalidate() { lock.withLock { invalidationCount += 1 } }
    }
}
