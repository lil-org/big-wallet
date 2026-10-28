import WalletDomain
// ∅ 2026 lil org

import CryptoKit
import Foundation
import LocalAuthentication
import Synchronization
import Security
import XCTest
@testable import WalletAuthority
import WalletRuntimeTestSupport

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

    @MainActor
    func testValidationLimitsRawUTF8BytesBeforeWhitespaceNormalization() async {
        let keychain = Keychain(
            copyMatching: { _, _ in XCTFail("Validation must not read Keychain"); return errSecParam },
            add: { _, _ in XCTFail("Validation must not add Keychain items"); return errSecParam },
            update: { _, _ in XCTFail("Validation must not update Keychain items"); return errSecParam },
            delete: { _ in XCTFail("Validation must not delete Keychain items"); return errSecParam }
        )
        let manager = WalletsManager(keychain: keychain)
        let mnemonic = Vectors.walletCoreJSONMnemonic
        let paddingBytes = WalletImportLimits.maximumInputBytes - mnemonic.utf8.count
        let atLimit = String(repeating: " ", count: paddingBytes) + mnemonic
        let aboveLimit = String(repeating: " ", count: paddingBytes - 2) + mnemonic + "\u{2003}"
        XCTAssertEqual(atLimit.utf8.count, WalletImportLimits.maximumInputBytes)
        XCTAssertEqual(aboveLimit.utf8.count, WalletImportLimits.maximumInputBytes + 1)
        XCTAssertLessThan(aboveLimit.count, WalletImportLimits.maximumInputBytes)

        let accepted = await manager.validateWalletInput(atLimit)
        let rejected = await manager.validateWalletInput(aboveLimit)

        XCTAssertTrue(accepted == .valid)
        XCTAssertTrue(rejected == .invalid)
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

private struct WalletSourceMutationStub: WalletSourceMutating {
    let onRevoke: @Sendable (WalletAuthorityRemoval) throws -> Void

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
    var beforeTransaction: @Sendable () throws -> Void = {}
    var beforePreparation: @Sendable () -> Void = {}
    var afterTransaction: @Sendable () -> Void = {}

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

private struct InvalidatingWalletSourceMutator: WalletSourceMutating {
    let invalidate: @Sendable () -> Void

    func perform<Payload, Result>(preparing: () throws -> PreparedWalletSourceMutation<Payload>,
                                 beforeCommit: () throws -> Void, commit: (Payload) throws -> Result) throws -> Result {
        let prepared = try preparing()
        try beforeCommit()
        invalidate()
        return try commit(prepared.payload)
    }
}

@MainActor
final class WalletRemovalIntegrationTests: XCTestCase {

    private enum TestError: Error {
        case cleanupFailed
    }

    func testEveryManagementOperationRejectsForeignInvalidatedExpiredOrChangedAccess() async throws {
        let fixture = try makeRemovalFixture()
        let manager = fixture.manager { _ in XCTFail("Unauthorized management must not revoke authority") }
        await assertWalletReload(manager)
        let wallet = try XCTUnwrap(manager.wallets.first)
        let original = fixture.keychain.walletData
        let invalidated = manager.accessForTesting()
        invalidated.invalidate()
        let now = Mutex(ContinuousClock.now)
        let expired = walletAccessForTesting(authorityID: manager.authorityID, clock: { now.withLock { $0 } })
        now.withLock { $0 += .seconds(15 * 60) }
        let status = Mutex(WalletCredentialIdentity.Status.current)
        let changed = walletAccessForTesting(authorityID: manager.authorityID, status: { status.withLock { $0 } })
        status.withLock { $0 = .changed }
        let sessions = [walletAccessForTesting(authorityID: UUID()), invalidated, expired, changed]
        let operations: [(WalletAccessSession) async throws -> Void] = [
            { _ = try await manager.createWallet(access: $0) },
            { _ = try await manager.addWallet(input: WalletCrypto.hexString(data: Vectors.onePrivateKey), inputPassword: nil, access: $0) },
            { try await manager.update(wallet: wallet, enabledAccounts: [wallet.accounts[0]], access: $0) },
            { try await manager.update(wallet: wallet, removeAccounts: [wallet.accounts[1]], access: $0) },
            { try await manager.delete(wallet: wallet, access: $0) },
            { _ = try await manager.previewSession(wallet: wallet, access: $0) },
        ]
        for session in sessions {
            for operation in operations {
                do {
                    try await operation(session)
                    XCTFail("Unauthorized management was accepted")
                } catch WalletCredentialError.authorizationUnavailable {}
            }
        }
        XCTAssertEqual(fixture.keychain.walletData, original)
        XCTAssertTrue(fixture.keychain.events.isEmpty)
    }

    func testAccessRevokedAtCommitPreventsEveryWalletMutation() async throws {
        for operation in 0..<5 {
            let fixture = try makeRemovalFixture()
            let active = Mutex<WalletAccessSession?>(nil)
            let manager = fixture.transactionManager(InvalidatingWalletSourceMutator {
                active.withLock { $0 }?.invalidate()
            })
            await assertWalletReload(manager)
            let wallet = try XCTUnwrap(manager.wallets.first)
            let access = manager.accessForTesting()
            active.withLock { $0 = access }
            let original = fixture.keychain.walletData
            do {
                switch operation {
                case 0: _ = try await manager.createWallet(access: access)
                case 1: _ = try await manager.addWallet(input: WalletCrypto.hexString(data: Vectors.onePrivateKey), inputPassword: nil, access: access)
                case 2: try await manager.update(wallet: wallet, enabledAccounts: [wallet.accounts[0]], access: access)
                case 3: try await manager.update(wallet: wallet, removeAccounts: [wallet.accounts[1]], access: access)
                default: try await manager.delete(wallet: wallet, access: access)
                }
                XCTFail("Revoked access committed a mutation")
            } catch WalletCredentialError.authorizationUnavailable {}
            XCTAssertEqual(fixture.keychain.walletData, original)
            XCTAssertTrue(fixture.keychain.events.isEmpty)
        }
    }

    func testWalletDeletionRetiresIdlePreviewWhileAccountMetadataEditPreservesIt() async throws {
        let fixture = try makeRemovalFixture()
        let manager = fixture.manager { _ in }
        await assertWalletReload(manager)
        let wallet = try XCTUnwrap(manager.wallets.first)
        let access = manager.accessForTesting()
        let preview = try await manager.previewSession(wallet: wallet, access: access)

        try await manager.update(wallet: wallet, enabledAccounts: [wallet.accounts[0]], access: access)
        XCTAssertTrue(preview.isActive)
        try await manager.delete(wallet: wallet, access: access)

        XCTAssertFalse(preview.isActive)
    }

    func testWalletDeletionRevokesBeforeSourceRemovalAndPreservesSiblingMetadata() async throws {
        let fixture = try makeRemovalFixture()
        let removals = Mutex([WalletAuthorityRemoval]())
        let manager = fixture.manager { removal in
            removals.withLock { $0.append(removal) }
            fixture.keychain.events.append("cleanup")
            XCTAssertNotNil(fixture.keychain.walletData[fixture.walletID])
        }
        await assertWalletReload(manager)
        let wallet = try XCTUnwrap(manager.wallets.first { $0.id == fixture.walletID })
        let sibling = try XCTUnwrap(manager.wallets.first { $0.id == fixture.siblingID })
        let account = try XCTUnwrap(wallet.accounts.first)
        fixture.metadata.saveWalletName("Removed wallet", wallet: wallet)
        fixture.metadata.saveAccountName("Removed account", wallet: wallet, account: account)
        fixture.metadata.saveWalletName("Sibling wallet", wallet: sibling)
        fixture.metadata.saveAccountName("Sibling account", wallet: sibling, account: account)
        defer { fixture.clearMetadata() }

        try await manager.delete(wallet: wallet, access: manager.accessForTesting())

        XCTAssertEqual(removals.withLock { $0.count }, 1)
        guard case .wallet(let id)? = removals.withLock({ $0.first }) else { return XCTFail("Expected whole-wallet revocation") }
        XCTAssertEqual(id, fixture.walletID)
        XCTAssertEqual(fixture.keychain.events, ["cleanup", "delete"])
        XCTAssertNil(fixture.keychain.walletData[fixture.walletID])
        XCTAssertNotNil(fixture.keychain.walletData[fixture.siblingID])
        XCTAssertEqual(manager.wallets.map(\.id), [fixture.siblingID])
        XCTAssertNil(fixture.metadata.getWalletName(wallet: wallet))
        XCTAssertNil(fixture.metadata.getAccountName(walletId: wallet.id, account: account))
        XCTAssertEqual(fixture.metadata.getWalletName(wallet: sibling), "Sibling wallet")
        XCTAssertEqual(fixture.metadata.getAccountName(walletId: sibling.id, account: account), "Sibling account")
    }

    func testBothAccountRemovalPathsPreserveConcurrentAdditionsAndSiblingMetadata() async throws {
        for useEnabledAccounts in [false, true] {
            let fixture = try makeRemovalFixture()
            let removedAccounts = Mutex(Set<WalletAccountDescriptor>())
            let manager = fixture.manager { removal in
                guard case .accounts(let accounts) = removal else {
                    return XCTFail("Expected account-scoped revocation")
                }
                removedAccounts.withLock { $0.formUnion(accounts) }
                fixture.keychain.events.append("cleanup")
            }
            await assertWalletReload(manager)
            let wallet = try XCTUnwrap(manager.wallets.first { $0.id == fixture.walletID })
            let sibling = try XCTUnwrap(manager.wallets.first { $0.id == fixture.siblingID })
            let retained = wallet.accounts[0]
            let removed = wallet.accounts[1]
            let concurrent = fixture.additionalAccount(index: 2)
            fixture.keychain.walletData[fixture.walletID] = try fixture.walletData(adding: concurrent)
            fixture.metadata.saveWalletName("Kept wallet", wallet: wallet)
            fixture.metadata.saveAccountName("Retained", wallet: wallet, account: retained)
            fixture.metadata.saveAccountName("Removed", wallet: wallet, account: removed)
            fixture.metadata.saveAccountName("Concurrent", wallet: wallet, account: concurrent)
            fixture.metadata.saveAccountName("Other wallet", wallet: sibling, account: removed)
            defer { fixture.clearMetadata() }

            if useEnabledAccounts {
                try await manager.update(wallet: wallet, enabledAccounts: [retained], access: manager.accessForTesting())
            } else {
                try await manager.update(wallet: wallet, removeAccounts: [removed], access: manager.accessForTesting())
            }

            XCTAssertEqual(removedAccounts.withLock { $0 }, [WalletAccountDescriptor(walletID: wallet.id, account: removed)])
            XCTAssertEqual(fixture.keychain.events, ["cleanup", "update"])
            let persisted = try fixture.persistedWallet()
            XCTAssertEqual(Set(persisted.accounts.map(\.previewAccountKey)), [retained.previewAccountKey, concurrent.previewAccountKey])
            let current = try XCTUnwrap(manager.wallets.first { $0.id == wallet.id })
            XCTAssertEqual(current.accounts, persisted.accounts)
            XCTAssertEqual(fixture.metadata.getWalletName(wallet: wallet), "Kept wallet")
            XCTAssertNil(fixture.metadata.getAccountName(walletId: wallet.id, account: removed))
            XCTAssertEqual(fixture.metadata.getAccountName(walletId: wallet.id, account: retained), "Retained")
            XCTAssertEqual(fixture.metadata.getAccountName(walletId: wallet.id, account: concurrent), "Concurrent")
            XCTAssertEqual(fixture.metadata.getAccountName(walletId: sibling.id, account: removed), "Other wallet")
        }
    }

    func testAccountAddedAndGrantedAtTransactionEntrySurvivesBothRemovalPaths() async throws {
        for useEnabledAccounts in [false, true] {
            let fixture = try makeRemovalFixture()
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
            fixture.metadata.saveAccountName("Removed", wallet: staleWallet, account: removed)
            let transactionEntries = Mutex(0)
            let insideTransaction = Mutex(false)
            let grantConcurrent = try preparedGrant(concurrentDescriptor, in: store, id: 2, origin: concurrentOrigin)
            let manager = fixture.transactionManager(ObservedWalletSourceMutator(
                base: store,
                beforeTransaction: {
                    transactionEntries.withLock { $0 += 1 }
                    fixture.keychain.walletData[fixture.walletID] = try fixture.walletData(adding: concurrent)
                    try grantConcurrent()
                    fixture.metadata.saveAccountName("Concurrent", wallet: staleWallet, account: concurrent)
                },
                beforePreparation: { insideTransaction.withLock { $0 = true } },
                afterTransaction: { insideTransaction.withLock { $0 = false } }
            ))
            await assertWalletReload(manager)
            fixture.keychain.beforeWalletRead = { _ in
                XCTAssertTrue(insideTransaction.withLock { $0 }, "Source accounts must be read after acquiring the transaction")
            }
            fixture.keychain.beforeWalletWrite = {
                XCTAssertTrue(insideTransaction.withLock { $0 }, "Source accounts must be written before releasing the transaction")
            }

            if useEnabledAccounts {
                try await manager.update(wallet: staleWallet, enabledAccounts: [retained], access: manager.accessForTesting())
            } else {
                try await manager.update(wallet: staleWallet, removeAccounts: [removed], access: manager.accessForTesting())
            }
            fixture.keychain.beforeWalletRead = nil
            fixture.keychain.beforeWalletWrite = nil

            XCTAssertEqual(transactionEntries.withLock { $0 }, 1)
            XCTAssertEqual(fixture.keychain.events, ["update"])
            let persisted = try fixture.persistedWallet()
            XCTAssertEqual(Set(persisted.accounts.map(\.previewAccountKey)), [retained.previewAccountKey, concurrent.previewAccountKey])
            XCTAssertEqual(manager.wallets.first { $0.id == staleWallet.id }?.accounts, persisted.accounts)
            XCTAssertNil(fixture.metadata.getAccountName(walletId: staleWallet.id, account: removed))
            XCTAssertEqual(fixture.metadata.getAccountName(walletId: staleWallet.id, account: concurrent), "Concurrent")
            guard case .snapshot(let removedState) = store.configurationSnapshot(configurationKey: removedOrigin, profileIdentifier: nil),
                  case .snapshot(let concurrentState) = store.configurationSnapshot(configurationKey: concurrentOrigin, profileIdentifier: nil) else {
                return XCTFail("Expected current authority snapshots")
            }
            XCTAssertNil(removedState.ethereumAccount)
            XCTAssertEqual(concurrentState.ethereumAccount, concurrentDescriptor)
        }
    }

    func testAccountAdditionsAndWalletImportsUseTheSourceMutationBoundary() async throws {
        let fixture = try makeRemovalFixture()
        let transactionEntries = Mutex(0)
        let revocations = Mutex(0)
        let insideTransaction = Mutex(false)
        let manager = fixture.transactionManager(ObservedWalletSourceMutator(
            base: WalletSourceMutationStub(onRevoke: { _ in revocations.withLock { $0 += 1 } }),
            beforePreparation: {
                transactionEntries.withLock { $0 += 1 }
                insideTransaction.withLock { $0 = true }
            },
            afterTransaction: { insideTransaction.withLock { $0 = false } }
        ))
        await assertWalletReload(manager)
        let wallet = try XCTUnwrap(manager.wallets.first { $0.id == fixture.walletID })
        let added = fixture.additionalAccount(index: 2)
        fixture.keychain.beforeWalletRead = { _ in XCTAssertTrue(insideTransaction.withLock { $0 }) }
        fixture.keychain.beforeWalletWrite = { XCTAssertTrue(insideTransaction.withLock { $0 }) }

        try await manager.update(wallet: wallet, enabledAccounts: wallet.accounts + [added], access: manager.accessForTesting())

        XCTAssertEqual(transactionEntries.withLock { $0 }, 1)
        XCTAssertEqual(revocations.withLock { $0 }, 0)
        XCTAssertEqual(fixture.keychain.events, ["update"])
        fixture.keychain.beforeWalletRead = nil
        XCTAssertTrue(try fixture.persistedWallet().accounts.contains { $0.previewAccountKey == added.previewAccountKey })
        fixture.keychain.beforeWalletRead = { _ in XCTAssertTrue(insideTransaction.withLock { $0 }) }

        let imported = try await manager.addWallet(input: WalletCrypto.hexString(data: Vectors.onePrivateKey), inputPassword: nil, access: manager.accessForTesting())
        fixture.keychain.beforeWalletRead = nil
        fixture.keychain.beforeWalletWrite = nil

        XCTAssertEqual(transactionEntries.withLock { $0 }, 2)
        XCTAssertEqual(revocations.withLock { $0 }, 0)
        XCTAssertEqual(fixture.keychain.events, ["update", "add"])
        XCTAssertNotNil(fixture.keychain.walletData[imported.id])
    }

    func testWalletCreationAndImportDoNotPublishAfterFailedInsertion() async throws {
        for createWallet in [true, false] {
            for status in [errSecDuplicateItem, errSecIO] {
                let fixture = try makeRemovalFixture()
                let manager = fixture.manager { _ in XCTFail("Creation must not revoke authority") }
                await assertWalletReload(manager)
                let originalData = fixture.keychain.walletData
                let originalWallets = manager.wallets
                fixture.keychain.addStatus = status

                do {
                    if createWallet {
                        _ = try await manager.createWallet(access: manager.accessForTesting())
                    } else {
                        _ = try await manager.addWallet(
                            input: WalletCrypto.hexString(data: Vectors.onePrivateKey),
                            inputPassword: nil,
                            access: manager.accessForTesting()
                        )
                    }
                    XCTFail("Expected insertion failure")
                } catch WalletCredentialError.failedToSave(let actual) {
                    XCTAssertEqual(actual, status)
                }

                XCTAssertEqual(fixture.keychain.events, ["add"])
                XCTAssertEqual(fixture.keychain.walletData, originalData)
                XCTAssertEqual(manager.wallets, originalWallets)
                XCTAssertEqual(fixture.mutationCount, 0)
            }
        }
    }

    func testCanceledImportNeverEntersSourceCommit() async throws {
        let fixture = try makeRemovalFixture()
        let manager = fixture.transactionManager(ObservedWalletSourceMutator(
            base: WalletSourceMutationStub(onRevoke: { _ in XCTFail("Canceled imports must not revoke authority") }),
            beforeTransaction: { withUnsafeCurrentTask { $0?.cancel() } }
        ))
        await assertWalletReload(manager)
        let originalData = fixture.keychain.walletData
        let originalWallets = manager.wallets
        let operation = Task {
            try await manager.addWallet(input: WalletCrypto.hexString(data: Vectors.onePrivateKey), inputPassword: nil, access: manager.accessForTesting())
        }

        do {
            _ = try await operation.value
            XCTFail("Canceled preparation must not be committed")
        } catch is CancellationError {
        }

        XCTAssertTrue(fixture.keychain.events.isEmpty)
        XCTAssertEqual(fixture.keychain.walletData, originalData)
        XCTAssertEqual(manager.wallets, originalWallets)
    }

    func testFailedJSONDecryptionDoesNotEnterSourceMutation() async throws {
        let fixture = try makeRemovalFixture()
        let transactionEntries = Mutex(0)
        let manager = fixture.transactionManager(ObservedWalletSourceMutator(
            base: WalletSourceMutationStub(onRevoke: { _ in XCTFail("Unexpected revocation") }),
            beforeTransaction: { transactionEntries.withLock { $0 += 1 } }
        ))

        do {
            _ = try await manager.addWallet(
                input: String(decoding: Vectors.walletCoreJSONMnemonicFixture, as: UTF8.self),
                inputPassword: "incorrect password",
                access: manager.accessForTesting()
            )
            XCTFail("Expected decryption to fail")
        } catch WalletKeyStoreError.invalidPassword {
        }

        XCTAssertEqual(transactionEntries.withLock { $0 }, 0)
        XCTAssertTrue(fixture.keychain.events.isEmpty)
    }

    func testOversizedWalletInputRejectsValidationAndImportBeforeSourceMutation() async throws {
        let fixture = try makeRemovalFixture()
        let transactionEntries = Mutex(0)
        let manager = fixture.transactionManager(ObservedWalletSourceMutator(
            base: WalletSourceMutationStub(onRevoke: { _ in XCTFail("Rejected imports must not revoke authority") }),
            beforeTransaction: { transactionEntries.withLock { $0 += 1 } }
        ))
        await assertWalletReload(manager)
        let originalData = fixture.keychain.walletData
        let originalWallets = manager.wallets
        let maximumBytes = WalletImportLimits.maximumInputBytes
        let multiByteInput = String(repeating: "é", count: maximumBytes / 2 + 1)
        XCTAssertLessThan(multiByteInput.count, maximumBytes)
        let inputs = [
            String(repeating: " ", count: maximumBytes) + Vectors.walletCoreJSONMnemonic,
            multiByteInput,
            "{\"padding\":\"" + String(repeating: "a", count: maximumBytes) + "\"}",
        ]

        for input in inputs {
            XCTAssertGreaterThan(input.utf8.count, maximumBytes)
            let validation = await manager.validateWalletInput(input)
            XCTAssertTrue(validation == .invalid)
            do {
                _ = try await manager.addWallet(input: input, inputPassword: "password", access: manager.accessForTesting())
                XCTFail("Expected oversized input to be rejected")
            } catch WalletImportError.limitExceeded {
            }

            XCTAssertEqual(transactionEntries.withLock { $0 }, 0)
            XCTAssertTrue(fixture.keychain.events.isEmpty)
            XCTAssertEqual(fixture.keychain.walletData, originalData)
            XCTAssertEqual(manager.wallets, originalWallets)
        }
    }

    func testPBKDF2ImportBudgetRejectionPreservesExistingWalletSources() async throws {
        let fixture = try makeRemovalFixture()
        let transactionEntries = Mutex(0)
        let manager = fixture.transactionManager(ObservedWalletSourceMutator(
            base: WalletSourceMutationStub(onRevoke: { _ in XCTFail("Rejected imports must not revoke authority") }),
            beforeTransaction: { transactionEntries.withLock { $0 += 1 } }
        ))
        await assertWalletReload(manager)
        let originalData = fixture.keychain.walletData
        let originalWallets = manager.wallets
        let source = WalletRepository.Source(
            walletID: fixture.walletID,
            data: try XCTUnwrap(originalData[fixture.walletID]),
            password: try XCTUnwrap(fixture.keychain.passwordData)
        )
        let costs = [
            (rounds: WalletImportLimits.maximumPBKDF2Work + 1, keyLength: 32),
            (rounds: WalletImportLimits.maximumPBKDF2Work / 2 + 1, keyLength: 33),
        ]

        for cost in costs {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Vectors.walletCoreJSONVariantPrivateKeyFixtures[0].json
            ) as? [String: Any])
            var crypto = try XCTUnwrap(json["crypto"] as? [String: Any])
            var parameters = try XCTUnwrap(crypto["kdfparams"] as? [String: Any])
            parameters["c"] = cost.rounds
            parameters["dklen"] = cost.keyLength
            crypto["kdfparams"] = parameters
            json["crypto"] = crypto
            let input = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)

            do {
                _ = try await manager.addWallet(
                    input: input,
                    inputPassword: String(decoding: Vectors.walletCoreJSONPBKDF2PrivateKeyPassword, as: UTF8.self),
                    access: manager.accessForTesting()
                )
                XCTFail("Expected excessive PBKDF2 work to be rejected")
            } catch WalletImportError.limitExceeded {
            }

            XCTAssertEqual(transactionEntries.withLock { $0 }, 0)
            XCTAssertTrue(fixture.keychain.events.isEmpty)
            XCTAssertEqual(fixture.keychain.walletData, originalData)
            XCTAssertEqual(manager.wallets, originalWallets)
            XCTAssertTrue(try manager.repository.sourceIsCurrent(source.identity))
        }
    }

    func testAdmittedMnemonicSolanaAndJSONImportsRoundTripThroughManager() async throws {
        let fixture = try makeRemovalFixture()
        fixture.keychain.walletData = [:]
        let manager = fixture.manager { _ in XCTFail("Import must not revoke authority") }
        let inputs: [(input: String, password: String?, mnemonic: Bool, exported: String)] = [
            (Vectors.walletCoreJSONMnemonic, nil, true, Vectors.walletCoreJSONMnemonic),
            (
                String(decoding: Vectors.walletCoreJSONMnemonicFixture, as: UTF8.self),
                String(decoding: Vectors.walletCoreJSONMnemonicPassword, as: UTF8.self),
                true,
                Vectors.walletCoreJSONMnemonic
            ),
            (Vectors.solanaSequentialSecretKeyBase58, nil, false, Vectors.solanaSequentialSecretKeyBase58),
            (
                String(decoding: Vectors.walletCoreJSONVariantPrivateKeyFixtures[0].json, as: UTF8.self),
                String(decoding: Vectors.walletCoreJSONPBKDF2PrivateKeyPassword, as: UTF8.self),
                false,
                WalletCrypto.hexString(data: Vectors.secpPrivateKey)
            ),
        ]

        for entry in inputs {
            let validation = await manager.validateWalletInput(entry.input)
            XCTAssertTrue(validation == (entry.password == nil ? .valid : .requiresPassword))
            let wallet = try await manager.addWallet(input: entry.input, inputPassword: entry.password, access: manager.accessForTesting())
            let exported = entry.mnemonic
                ? try await exportMnemonicForTesting(manager: manager, wallet: wallet)
                : try await exportPrivateKeyForTesting(manager: manager, wallet: wallet)

            XCTAssertEqual(wallet.isMnemonic, entry.mnemonic)
            XCTAssertEqual(exported, entry.exported)
            XCTAssertNotNil(fixture.keychain.walletData[wallet.id])
        }
        XCTAssertEqual(manager.wallets.count, inputs.count)
    }

    func testExistingWalletDecryptsWithBOMPrefixedStoredPassword() async throws {
        let fixture = try makeRemovalFixture()
        let stored = Data([0xef, 0xbb, 0xbf]) + Vectors.walletCoreJSONMnemonicPassword
        fixture.keychain.passwordData = stored
        let manager = fixture.manager { _ in XCTFail("Export must not revoke authority") }
        await assertWalletReload(manager)
        let wallet = try XCTUnwrap(manager.wallets.first { $0.id == fixture.walletID })

        let mnemonic = try await exportMnemonicForTesting(manager: manager, wallet: wallet)

        XCTAssertEqual(mnemonic, Vectors.walletCoreJSONMnemonic)
        XCTAssertEqual(fixture.keychain.passwordData, stored)
        XCTAssertTrue(fixture.keychain.events.isEmpty)
    }

    func testImportedWalletRoundTripsWithBOMPrefixedStoredPassword() async throws {
        let input = WalletCrypto.hexString(data: Vectors.onePrivateKey)
        for count in 1...2 {
            let fixture = try makeRemovalFixture()
            let stored = Data((String(repeating: "\u{feff}", count: count) + "password").utf8)
            fixture.keychain.passwordData = stored
            fixture.keychain.walletData = [:]
            let manager = fixture.manager { _ in XCTFail("Import must not revoke authority") }

            let wallet = try await manager.addWallet(input: input, inputPassword: nil, access: manager.accessForTesting())
            let exported = try await exportPrivateKeyForTesting(manager: manager, wallet: wallet)

            XCTAssertEqual(exported, input)
            XCTAssertEqual(fixture.keychain.passwordData, stored)
        }
    }

    func testWalletCreationAndImportRejectChangedOrMissingPasswordBeforeCommit() async throws {
        for createWallet in [true, false] {
            for passwordData: Data? in [Data("changed password".utf8), nil] {
                let fixture = try makeRemovalFixture()
                let transactionEntries = Mutex(0)
                let manager = fixture.transactionManager(ObservedWalletSourceMutator(
                    base: WalletSourceMutationStub(onRevoke: { _ in XCTFail("Unexpected revocation") }),
                    beforeTransaction: {
                        transactionEntries.withLock { $0 += 1 }
                        fixture.keychain.passwordData = passwordData
                    }
                ))
                await assertWalletReload(manager)
                let originalData = fixture.keychain.walletData
                let originalWalletIDs = manager.wallets.map(\.id)

                do {
                    if createWallet {
                        _ = try await manager.createWallet(access: manager.accessForTesting())
                    } else {
                        _ = try await manager.addWallet(
                            input: WalletCrypto.hexString(data: Vectors.onePrivateKey),
                            inputPassword: nil,
                            access: manager.accessForTesting()
                        )
                    }
                    XCTFail("Expected the stale password to prevent saving")
                } catch WalletsManager.Error.keychainAccessFailure {
                }

                XCTAssertEqual(transactionEntries.withLock { $0 }, 1)
                XCTAssertTrue(fixture.keychain.events.isEmpty)
                XCTAssertEqual(fixture.keychain.walletData, originalData)
                XCTAssertEqual(manager.wallets.map(\.id), originalWalletIDs)
            }
        }
    }

    func testPreparedDeletionRejectsChangedWalletOrCredentialBeforeMutation() async throws {
        enum Change: CaseIterable { case wallet, credential, missingWallet }
        for change in Change.allCases {
            let fixture = try makeRemovalFixture()
            let manager = fixture.manager { _ in XCTFail("Stale deletion must not revoke authority") }
            await assertWalletReload(manager)
            let wallet = try XCTUnwrap(manager.wallets.first { $0.id == fixture.walletID })
            let prepared = try await manager.repository.prepareDeletion(wallet: wallet)
            XCTAssertEqual(prepared.wallet, wallet)
            switch change {
            case .wallet:
                fixture.keychain.walletData[wallet.id] = try XCTUnwrap(fixture.keychain.walletData[wallet.id]) + Data([32])
            case .credential:
                fixture.keychain.passwordData = Data("replacement".utf8)
            case .missingWallet:
                fixture.keychain.walletData[wallet.id] = nil
            }
            let retained = fixture.keychain.walletData

            do {
                _ = try await manager.repository.delete(prepared, willMutateSource: {
                    XCTFail("Stale deletion must fail before mutation")
                })
                XCTFail("Stale deletion was committed")
            } catch WalletsManager.Error.keychainAccessFailure {
            }

            XCTAssertTrue(fixture.keychain.events.isEmpty)
            XCTAssertEqual(fixture.keychain.walletData, retained)
        }
    }

    func testCleanupFailureLeavesSourceAndMetadataUnchanged() async throws {
        for operation in RemovalOperation.allCases {
            let fixture = try makeRemovalFixture()
            let cleanupAttempts = Mutex(0)
            let manager = fixture.manager { _ in
                cleanupAttempts.withLock { $0 += 1 }
                throw TestError.cleanupFailed
            }
            await assertWalletReload(manager)
            let wallet = try XCTUnwrap(manager.wallets.first { $0.id == fixture.walletID })
            let originalData = fixture.keychain.walletData
            let originalAccounts = wallet.accounts
            let account = wallet.accounts[1]
            fixture.metadata.saveAccountName("Still present", wallet: wallet, account: account)
            defer { fixture.clearMetadata() }

            do {
                try await operation.apply(manager: manager, wallet: wallet)
                XCTFail("Cleanup failure must prevent the source mutation")
            } catch TestError.cleanupFailed {
            }

            XCTAssertEqual(cleanupAttempts.withLock { $0 }, 1)
            XCTAssertTrue(fixture.keychain.events.isEmpty)
            XCTAssertEqual(fixture.keychain.walletData, originalData)
            XCTAssertEqual(manager.wallets.first { $0.id == wallet.id }?.accounts, originalAccounts)
            XCTAssertEqual(fixture.metadata.getAccountName(walletId: wallet.id, account: account), "Still present")
        }
    }

    func testSourceWriteFailureKeepsCleanupAppliedWithoutDeletingMetadata() async throws {
        for operation in RemovalOperation.allCases {
            let fixture = try makeRemovalFixture()
            fixture.keychain.deleteStatus = errSecInteractionNotAllowed
            fixture.keychain.updateStatus = errSecInteractionNotAllowed
            let cleanupApplied = Mutex(false)
            let manager = fixture.manager { _ in
                cleanupApplied.withLock { $0 = true }
                fixture.keychain.events.append("cleanup")
            }
            await assertWalletReload(manager)
            let wallet = try XCTUnwrap(manager.wallets.first { $0.id == fixture.walletID })
            let originalData = fixture.keychain.walletData
            let originalAccounts = wallet.accounts
            let account = wallet.accounts[1]
            fixture.metadata.saveAccountName("Still present", wallet: wallet, account: account)
            defer { fixture.clearMetadata() }

            do {
                try await operation.apply(manager: manager, wallet: wallet)
                XCTFail("Expected the source write failure")
            } catch is WalletCredentialError {
            }

            XCTAssertTrue(cleanupApplied.withLock { $0 })
            XCTAssertEqual(fixture.keychain.events, ["cleanup", operation == .wallet ? "delete" : "update"])
            XCTAssertEqual(fixture.keychain.walletData, originalData)
            XCTAssertEqual(manager.wallets.first { $0.id == wallet.id }?.accounts, originalAccounts)
            XCTAssertEqual(fixture.metadata.getAccountName(walletId: wallet.id, account: account), "Still present")
        }
    }

    func testDeletingAndReimportingTheSameKeyRequiresFreshSiteApproval() async throws {
        let fixture = try makeRemovalFixture()
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
        await assertWalletReload(manager)
        let wallet = try XCTUnwrap(manager.wallets.first { $0.id == fixture.walletID })
        let account = try XCTUnwrap(wallet.accounts.first)
        let descriptor = WalletAccountDescriptor(walletID: wallet.id, account: account)
        let origin = "https://wallet-removal.example"

        try grant(descriptor, in: store, id: 1, origin: origin)
        guard case .snapshot(let granted) = store.configurationSnapshot(configurationKey: origin, profileIdentifier: nil) else {
            return XCTFail("Expected the original grant")
        }
        XCTAssertEqual(granted.ethereumAccount, descriptor)

        try await manager.delete(wallet: wallet, access: manager.accessForTesting())
        let reimported = try await manager.addWallet(input: WalletCrypto.hexString(data: Vectors.onePrivateKey), inputPassword: nil, access: manager.accessForTesting())

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
        let binding = try XCTUnwrap(retry.requestBinding)
        guard case .needsCatalog = requestProcessorForTesting().prepare(binding, catalog: nil) else {
            return XCTFail("Expected a catalog requirement")
        }
        let catalog = try XCTUnwrap(manager.reviewCatalog())
        guard case .approval(let intent) = requestProcessorForTesting().prepare(binding, catalog: catalog),
              case .selectAccount = intent.action else {
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
        try preparedGrant(account, in: store, id: id, origin: origin)()
    }

    private func preparedGrant(_ account: WalletAccountDescriptor, in store: ExtensionRequestFileStore, id: Int, origin: String) throws -> @Sendable () throws -> Void {
        let initial = try connection(in: store, id: id, origin: origin)
        let approval = try resolvedApprovalForTesting(
            snapshot: initial,
            action: .selectAccount(.init(
                coinType: .ethereum, selectedAccounts: [],
                initiallyConnectedProviders: [], network: AuthorityTestNetworks.ethereum
            )),
            decision: .accountSelection(.init(accounts: [account], ethereumChainID: "0x1")),
            accounts: [account.specificAccount], approvedAt: Date()
        )
        guard case .claimed(let claim) = store.claim(handle: initial.handle),
              claim.adoptForExecution(),
              case .authorized(let permit) = store.authorize(claim: claim, approval: approval),
              permit.consumeExecution(),
              let completion = accountSelectionCompletionForTesting(permit: permit) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return {
            guard store.complete(permit: permit, result: completion) == .persisted else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private enum RemovalOperation: CaseIterable {
        case wallet, accounts, enabledAccounts

        @MainActor
        func apply(manager: WalletsManager, wallet: WalletSnapshot) async throws {
            switch self {
            case .wallet:
                try await manager.delete(wallet: wallet, access: manager.accessForTesting())
            case .accounts:
                try await manager.update(wallet: wallet, removeAccounts: [wallet.accounts[1]], access: manager.accessForTesting())
            case .enabledAccounts:
                try await manager.update(wallet: wallet, enabledAccounts: [wallet.accounts[0]], access: manager.accessForTesting())
            }
        }
    }

    private func makeRemovalFixture() throws -> RemovalFixture {
        let fixture = try RemovalFixture()
        addTeardownBlock { await fixture.cleanup() }
        return fixture
    }

    private final class RemovalFixture: Sendable {
        let walletID = "removal-test-\(UUID().uuidString)"
        let siblingID = "removal-sibling-\(UUID().uuidString)"
        let keychain = WalletRemovalKeychainStub()
        private let mutations = Mutex(0)
        var mutationCount: Int { mutations.withLock { $0 } }
        private let metadataSuite = "WalletRemovalMetadataTests.\(UUID().uuidString)"
        let metadata: WalletsMetadataService
#if os(iOS) || os(visionOS)
        private let vaultDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("WalletRemovalVault-\(UUID().uuidString)", isDirectory: true)
        private let vaultHosts = Mutex([SafariApprovalVaultHost]())
#endif

        init() throws {
#if os(iOS) || os(visionOS)
            try FileManager.default.createDirectory(at: vaultDirectory, withIntermediateDirectories: true)
#endif
            metadata = WalletsMetadataService(storage: try XCTUnwrap(UserDefaultsPreferenceStorage(suiteName: metadataSuite)))
            let data = try walletData()
            keychain.walletData = [walletID: data, siblingID: data]
        }

        @MainActor
        func manager(onRevoke: @escaping @Sendable (WalletAuthorityRemoval) throws -> Void) -> WalletsManager {
            transactionManager(WalletSourceMutationStub(onRevoke: onRevoke))
        }

        @MainActor
        func transactionManager(_ mutator: any WalletSourceMutating) -> WalletsManager {
            let manager = WalletsManager(
                keychain: Keychain(copyMatching: keychain.copyMatching, add: keychain.add,
                                   update: keychain.update, delete: keychain.delete),
                walletSourceMutator: mutator,
                notifications: .init(postLocalChange: {}, postMutation: { [self] in mutations.withLock { $0 += 1 } }, startObserving: { _, _ in },
                    stopObserving: { _ in }, isExternalChange: { _ in false }),
                metadataMutations: metadata.mutations
            )
#if os(iOS) || os(visionOS)
            let keys = WalletRemovalFixtureVaultKeys()
            let vault = SafariApprovalVault(fileURL: vaultDirectory.appendingPathComponent(UUID().uuidString), keyStore: keys,
                canEvaluateAuthentication: { _, _ in XCTFail("Source mutation must not authenticate"); return false },
                authentication: { _, _, _ in XCTFail("Source mutation must not authenticate"); return false })
            let host = SafariApprovalVaultHost(vault: vault, defaults: UserDefaultsPreferenceStorage(suiteName: metadataSuite)!,
                integrityKeyStore: keys, sourceSnapshot: { nil })
            vaultHosts.withLock { $0.append(host) }
            manager.approvalVaultHost = host
#endif
            return manager
        }

        func cleanup() async {
#if os(iOS) || os(visionOS)
            for host in vaultHosts.withLock({ $0 }) { await host.waitForReconciliation() }
            try? FileManager.default.removeItem(at: vaultDirectory)
#endif
            UserDefaults.standard.removePersistentDomain(forName: metadataSuite)
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

        func persistedWallet() throws -> WalletSnapshot {
            let data = try XCTUnwrap(keychain.walletData[walletID])
            let key = try XCTUnwrap(WalletStoredKey.importJSON(json: data))
            return WalletSnapshot(WalletContainer(id: walletID, key: key))
        }

        deinit { UserDefaults.standard.removePersistentDomain(forName: metadataSuite) }

        func clearMetadata() {
            for id in [walletID, siblingID] {
                guard let key = WalletStoredKey.importJSON(json: Vectors.walletCoreJSONMnemonicFixture) else { continue }
                metadata.removeMetadataForWallet(WalletSnapshot(WalletContainer(id: id, key: key)), postChange: false)
            }
        }
    }
}

private final class WalletRemovalKeychainStub: Sendable {
    private let walletPrefix = "org.lil.wallet.wallet."
    private struct State: Sendable {
        var walletData: [String: Data] = [:]
        var passwordData: Data? = Vectors.walletCoreJSONMnemonicPassword
        var events: [String] = []
        var addStatus: OSStatus = errSecSuccess
        var deleteStatus: OSStatus = errSecSuccess
        var updateStatus: OSStatus = errSecSuccess
        var beforeWalletRead: (@Sendable (String) -> Void)? = nil
        var beforeWalletWrite: (@Sendable () -> Void)? = nil
    }
    private let state = Mutex(State())

    var walletData: [String: Data] {
        get { state.withLock { $0.walletData } }
        set { state.withLock { $0.walletData = newValue } }
    }

    var passwordData: Data? {
        get { state.withLock { $0.passwordData } }
        set { state.withLock { $0.passwordData = newValue } }
    }

    var events: [String] {
        get { state.withLock { $0.events } }
        set { state.withLock { $0.events = newValue } }
    }

    var deleteStatus: OSStatus {
        get { state.withLock { $0.deleteStatus } }
        set { state.withLock { $0.deleteStatus = newValue } }
    }

    var addStatus: OSStatus {
        get { state.withLock { $0.addStatus } }
        set { state.withLock { $0.addStatus = newValue } }
    }

    var updateStatus: OSStatus {
        get { state.withLock { $0.updateStatus } }
        set { state.withLock { $0.updateStatus = newValue } }
    }

    var beforeWalletRead: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.beforeWalletRead } }
        set { state.withLock { $0.beforeWalletRead = newValue } }
    }

    var beforeWalletWrite: (@Sendable () -> Void)? {
        get { state.withLock { $0.beforeWalletWrite } }
        set { state.withLock { $0.beforeWalletWrite = newValue } }
    }

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
            guard let passwordData else { return errSecItemNotFound }
            result?.pointee = passwordData as CFData
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
        state.withLock { $0.events.append("add") }
        beforeWalletWrite?()
        let id = String(key.dropFirst(walletPrefix.count))
        return state.withLock { state in
            guard state.addStatus == errSecSuccess else { return state.addStatus }
            guard state.walletData[id] == nil else { return errSecDuplicateItem }
            state.walletData[id] = data
            return errSecSuccess
        }
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

@MainActor
final class WalletSigningScopeTests: XCTestCase {

    private let walletID = "approved-wallet"

    func testFailedPreparationRetiresSourceWithoutConsumingMismatchedPermit() async throws {
        let approved = descriptor()
        let alternatives = [
            WalletAccountDescriptor(walletID: "other-wallet", account: approved.account),
            descriptor(address: Vectors.oneEthereumAddress),
            descriptor(path: "m/44'/60'/0'/0/1"),
            WalletAccountDescriptor(walletID: walletID, account: solanaAccount()),
        ]
        for alternative in alternatives {
            let backing = SigningProbe()
            let access = requestAccess(approved: approved, backing: backing)
            let permit = try approvedWalletSigningPermitForTesting(approvedAccount: alternative)
            XCTAssertNil(access.consume(permit: permit))
            XCTAssertTrue(backing.operations.isEmpty)
            XCTAssertEqual(backing.retirements, 1)
            XCTAssertFalse(access.validateCurrent())
            XCTAssertNil(access.consume(permit: try approvedWalletSigningPermitForTesting(approvedAccount: approved)))

            let matchingBacking = SigningProbe()
            let matching = requestAccess(approved: alternative, backing: matchingBacking)
            let signer = try XCTUnwrap(matching.consume(permit: permit))
            guard case .success = await signer.sign() else {
                return XCTFail("A rejected preparation must leave the permit available to its matching source")
            }
            XCTAssertEqual(matchingBacking.operations.map(\.approvedAccount), [alternative])
            XCTAssertEqual(matchingBacking.operations.first?.handle, permit.handle)
            XCTAssertEqual(matchingBacking.operations.first?.deadline, permit.signingDeadline)
        }
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
        let accessPreparation = requestAccess(approved: approved, backing: SigningProbe())
        let permit = try approvedWalletSigningPermitForTesting(
            approvedAccount: WalletAccountDescriptor(walletID: walletID, account: reconstructed)
        )
        let access = try XCTUnwrap(accessPreparation.consume(permit: permit))
        XCTAssertEqual(access.approvedAccount, approved)
    }

    func testPreparationPreservesSolanaAddressCase() throws {
        let account = solanaAccount()
        let approved = WalletAccountDescriptor(walletID: walletID, account: account)
        let accessPreparation = requestAccess(approved: approved, backing: SigningProbe())
        let changed = WalletAccountDescriptor(
            walletID: walletID,
            coin: .solana,
            normalizedAddress: account.address.replacingOccurrences(of: "C", with: "c"),
            derivationPath: account.derivationPath
        )
        XCTAssertTrue(changed.isValid)
        let changedPermit = try approvedWalletSigningPermitForTesting(approvedAccount: changed)
        XCTAssertNil(accessPreparation.consume(permit: changedPermit))
        XCTAssertFalse(accessPreparation.validateCurrent())
        let matching = requestAccess(approved: changed, backing: SigningProbe())
        let changedAccess = try XCTUnwrap(matching.consume(permit: changedPermit))
        XCTAssertEqual(changedAccess.approvedAccount, changed)
        let fresh = requestAccess(approved: approved, backing: SigningProbe())
        let access = try XCTUnwrap(fresh.consume(permit: try approvedWalletSigningPermitForTesting(approvedAccount: approved)))
        XCTAssertEqual(access.approvedAccount, approved)
    }

    func testAccessAndSignerAreSingleUseAfterSuccessAndFailure() async throws {
        for succeeds in [false, true] {
            let backing = SigningProbe()
            backing.failure = succeeds ? nil : .failedToSign
            let access = requestAccess(approved: descriptor(), backing: backing)
            let permit = try approvedWalletSigningPermitForTesting(approvedAccount: descriptor())

            let signer = try XCTUnwrap(access.consume(permit: permit))
            XCTAssertNil(access.consume(permit: permit))
            _ = await signer.sign()
            assertUnavailable(await signer.sign())
            XCTAssertNil(access.consume(permit: permit))
            XCTAssertEqual(backing.operations.count, 1)
            XCTAssertEqual(backing.retirements, 1)
        }
    }

    func testOwnerInvalidationBeforeSigningReleasesAuthorization() async throws {
        for invalidateAccess in [false, true] {
            let backing = SigningProbe()
            let access = requestAccess(approved: descriptor(), backing: backing)
            let permit = try approvedWalletSigningPermitForTesting(approvedAccount: descriptor())

            if invalidateAccess {
                access.invalidate()
                XCTAssertNil(access.consume(permit: permit))
                XCTAssertFalse(access.validateCurrent())
                let matching = requestAccess(approved: descriptor(), backing: SigningProbe())
                XCTAssertNotNil(matching.consume(permit: permit))
            } else {
                let signer = try XCTUnwrap(access.consume(permit: permit))
                signer.invalidate()
                assertUnavailable(await signer.sign())
                assertUnavailable(await signer.sign())
            }
            XCTAssertEqual(backing.retirements, 1)
            XCTAssertTrue(backing.operations.isEmpty)
            XCTAssertNil(access.consume(permit: permit))
            XCTAssertEqual(backing.retirements, 1)
        }
    }

    func testPreparationInvalidationAfterTransferDoesNotInvalidateBoundSession() async throws {
        let backing = SigningProbe()
        let access = requestAccess(approved: descriptor(), backing: backing)
        let permit = try approvedWalletSigningPermitForTesting(approvedAccount: descriptor())
        let signer = try XCTUnwrap(access.consume(permit: permit))

        access.invalidate()
        XCTAssertFalse(access.validateCurrent())
        XCTAssertNil(access.consume(permit: permit))
        XCTAssertEqual(backing.retirements, 0)
        guard case .success = await signer.sign() else {
            return XCTFail("The bound session must own the transferred source")
        }
        XCTAssertEqual(backing.operations.count, 1)
        XCTAssertEqual(backing.retirements, 1)
        signer.invalidate()
        XCTAssertEqual(backing.retirements, 1)
    }

    func testConcurrentSigningConsumesAuthorizationBeforeSuspension() async throws {
        let backing = SigningProbe()
        let started = expectation(description: "Signing started")
        let release = TestGate<Void>()
        defer { release.resolve(()) }
        backing.beforeReturn = {
            started.fulfill()
            await release.wait()
        }
        let access = requestAccess(approved: descriptor(), backing: backing)

        let signer = try XCTUnwrap(access.consume(permit: try approvedWalletSigningPermitForTesting(approvedAccount: descriptor())))
        let first = Task { await signer.sign() }
        await fulfillment(of: [started], timeout: 1)
        assertUnavailable(await signer.sign())
        XCTAssertEqual(backing.operations.count, 1)
        release.resolve(())
        _ = await first.value
    }

    func testConcurrentSigningCannotReuseAuthorizationDuringEitherAuthorityCheck() async throws {
        for suspendedCheck in 1...2 {
            let backing = SigningProbe()
            let checking = expectation(description: "Authority check \(suspendedCheck) started")
            let sourceCheck = WalletSigningSourceCheckGate(started: checking)
            defer { sourceCheck.release() }
            let access = requestAccess(approved: descriptor(), backing: backing, isCurrent: sourceCheck.check)
            let permit = try approvedWalletSigningPermitForTesting(approvedAccount: descriptor())

            let signer = try XCTUnwrap(access.consume(permit: permit))
            sourceCheck.arm(check: suspendedCheck)
            let first = Task { await signer.sign() }
            await fulfillment(of: [checking], timeout: 1)
            assertUnavailable(await signer.sign())
            XCTAssertEqual(backing.operations.count, suspendedCheck - 1)
            XCTAssertEqual(backing.retirements, 0)
            sourceCheck.release()
            guard case .success = await first.value else {
                return XCTFail("The original signing call must retain its authorization")
            }
            XCTAssertEqual(backing.operations.count, 1)
            XCTAssertEqual(backing.retirements, 1)
        }
    }

    func testAuthoritySuspensionCannotOutliveAuthorizationBeforeOrAfterSigning() async throws {
        enum Interruption: CaseIterable {
            case expired, invalidated, canceled, sourceChanged
        }
        for suspendedCheck in 1...2 {
            for interruption in Interruption.allCases {
                let start = Date()
                var now = start
                let checking = expectation(description: "Authority check \(suspendedCheck): \(interruption)")
                let sourceCheck = WalletSigningSourceCheckGate(started: checking)
                defer { sourceCheck.release() }
                let backing = SigningProbe()
                let access = requestAccess(
                    approved: descriptor(), backing: backing, deadline: start.addingTimeInterval(1),
                    isCurrent: sourceCheck.check, clock: { now }
                )
                let permit = try approvedWalletSigningPermitForTesting(
                    approvedAccount: descriptor(), deadline: start.addingTimeInterval(1)
                )

                let signer = try XCTUnwrap(access.consume(permit: permit))
                sourceCheck.arm(check: suspendedCheck)
                let signing = Task { await signer.sign() }
                await fulfillment(of: [checking], timeout: 1)
                switch interruption {
                case .expired: now = start.addingTimeInterval(1)
                case .invalidated: signer.invalidate()
                case .canceled: signing.cancel()
                case .sourceChanged: sourceCheck.invalidateSource()
                }
                if interruption == .invalidated || interruption == .canceled {
                    XCTAssertEqual(backing.retirements, 1)
                }
                sourceCheck.release()
                assertUnavailable(await signing.value)
                assertUnavailable(await signer.sign())
                XCTAssertEqual(backing.operations.count, suspendedCheck - 1)
                XCTAssertEqual(backing.retirements, 1)
                signer.invalidate()
                access.invalidate()
                XCTAssertEqual(backing.retirements, 1)
            }
        }
    }

    func testExpiryBeforeSigningNeverReachesBacking() async throws {
        let start = Date()
        var now = start
        let backing = SigningProbe()
        let access = requestAccess(approved: descriptor(), backing: backing, deadline: start.addingTimeInterval(1), clock: { now })

        let signer = try XCTUnwrap(access.consume(permit: try approvedWalletSigningPermitForTesting(
            approvedAccount: descriptor(), deadline: start.addingTimeInterval(1)
        )))
        now = start.addingTimeInterval(1)
        assertUnavailable(await signer.sign())
        now = start
        assertUnavailable(await signer.sign())
        XCTAssertTrue(backing.operations.isEmpty)
    }

    func testCancellationBeforeSigningConsumesAuthorizationWithoutBackingAccess() async throws {
        let backing = SigningProbe()
        let access = requestAccess(approved: descriptor(), backing: backing)

        let signer = try XCTUnwrap(access.consume(permit: try approvedWalletSigningPermitForTesting(approvedAccount: descriptor())))
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
            let current = Mutex(true)
            let backing = SigningProbe()
            let started = expectation(description: "Signing started")
            let release = TestGate<Void>()
            defer { release.resolve(()) }
            backing.beforeReturn = {
                started.fulfill()
                await release.wait()
            }
            let access = requestAccess(
                approved: descriptor(), backing: backing, deadline: start.addingTimeInterval(1),
                isCurrent: { current.withLock { $0 } }, clock: { now }
            )

            let signer = try XCTUnwrap(access.consume(permit: try approvedWalletSigningPermitForTesting(
                approvedAccount: descriptor(), deadline: start.addingTimeInterval(1)
            )))
            let signing = Task { await signer.sign() }
            await fulfillment(of: [started], timeout: 1)
            switch interruption {
            case 0: signer.invalidate()
            case 1: now = start.addingTimeInterval(1)
            case 2: signing.cancel()
            default: current.withLock { $0 = false }
            }
            if interruption == 0 || interruption == 2 {
                XCTAssertEqual(backing.retirements, 1)
            }
            release.resolve(())
            assertUnavailable(await signing.value)
            assertUnavailable(await signer.sign())
            XCTAssertEqual(backing.operations.count, 1)
        }
    }

    func testSigningConsumptionDoesNotConsumeExecutionLease() async throws {
        let backing = SigningProbe()
        let access = requestAccess(approved: descriptor(), backing: backing)

        let signer = try XCTUnwrap(access.consume(permit: try approvedWalletSigningPermitForTesting(approvedAccount: descriptor())))
        _ = await signer.sign()
        let firstCommit = await signer.takeCommit()
        let firstLease = try walletCommitLeaseForTesting(firstCommit)
        firstLease.release()
        let secondCommit = await signer.takeCommit()
        assertWalletCommitUnavailableForTesting(secondCommit)
        assertUnavailable(await signer.sign())
    }

    func testStaleAndInvalidScopesDoNotConsumePermit() throws {
        let permit = try approvedWalletSigningPermitForTesting(approvedAccount: descriptor())
        for approved in [
            WalletAccountDescriptor(walletID: "", account: descriptor().account),
            descriptor(address: "0x1234"),
            descriptor(path: ""),
        ] {
            let backing = SigningProbe()
            let access = requestAccess(approved: approved, backing: backing)
            XCTAssertNil(access.consume(permit: permit))
            XCTAssertTrue(backing.operations.isEmpty)
            XCTAssertEqual(backing.retirements, 1)
        }
        let backing = SigningProbe()
        let stale = requestAccess(approved: descriptor(), backing: backing, isCurrent: { false })
        XCTAssertNil(stale.consume(permit: permit))
        XCTAssertTrue(backing.operations.isEmpty)
        XCTAssertEqual(backing.retirements, 1)
        let current = requestAccess(approved: descriptor(), backing: SigningProbe())
        let signer = try XCTUnwrap(current.consume(permit: permit))
        XCTAssertEqual(signer.approvedAccount, descriptor())
    }

    func testSourceRevocationDuringKeyDerivationPreventsSigning() async throws {
        enum Revocation: CaseIterable { case permission, wallet, credential }
        for revocation in Revocation.allCases {
            let reader = KeychainCopyMatchingStub()
            reader.attributes = [reader.walletAttributes(id: walletID)]
            reader.walletData = [walletID: Vectors.walletCoreJSONPrivateKeyFixture]
            reader.passwordData = Vectors.walletCoreJSONPrivateKeyPassword
            let derivationStarted = expectation(description: "Key derivation suspended")
            let gate = TestGate<Void>()
            let key = try XCTUnwrap(WalletPrivateKey(data: Vectors.walletCoreJSONPrivateKeyData))
            let manager = WalletsManager(
                keychain: Keychain(copyMatching: reader.copyMatching),
                keyDerivation: .init(derive: { _, _ in
                    derivationStarted.fulfill()
                    await gate.wait()
                    return key
                })
            )
            await assertWalletReload(manager)
            let account = try XCTUnwrap(manager.wallets.first?.accounts.first)
            let approved = WalletAccountDescriptor(walletID: walletID, account: account)
            let fixture = try ApprovedExecutionTestFixture()
            let permit = try sourceSigningPermit(in: fixture, account: approved)
            let sessionPreparation = WalletSigningPreparation.fromSource(
                scope: try XCTUnwrap(WalletSigningScope(permit: permit)), walletsManager: manager
            )
            let session = try XCTUnwrap(sessionPreparation.consume(permit: permit))
            let signing = Task { await session.sign() }
            await fulfillment(of: [derivationStarted], timeout: 2)

            switch revocation {
            case .permission:
                guard case .snapshot(let authority) = fixture.store.configurationSnapshot(
                    configurationKey: "https://wallet.example", profileIdentifier: nil
                ), case .revoked = fixture.store.revoke(
                    configurationKey: "https://wallet.example", provider: .ethereum,
                    attempt: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), expected: authority.version, profileIdentifier: nil
                ) else {
                    gate.resolve(())
                    _ = await signing.value
                    return XCTFail("Expected authority revocation during derivation")
                }
            case .wallet:
                reader.walletData[walletID] = nil
            case .credential:
                reader.passwordData = Data("replacement".utf8)
            }
            gate.resolve(())

            assertUnavailable(await signing.value)
            assertUnavailable(await session.sign())
        }
    }

    func testCancellationRetiresSourceCredentialBeforeSuspendedDerivationReturns() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: walletID)]
        reader.walletData = [walletID: Vectors.walletCoreJSONPrivateKeyFixture]
        reader.passwordData = Vectors.walletCoreJSONPrivateKeyPassword
        let started = expectation(description: "Derivation owns its source credential")
        let gate = TestGate<Void>()
        let retainedCredential = Mutex<SecretBytes?>(nil)
        let key = try XCTUnwrap(WalletPrivateKey(data: Vectors.walletCoreJSONPrivateKeyData))
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching), keyDerivation: .init(derive: { source, _ in
            retainedCredential.withLock { $0 = source.password }
            started.fulfill()
            await gate.wait()
            return key
        }))
        await assertWalletReload(manager)
        let account = try XCTUnwrap(manager.wallets.first?.accounts.first)
        let permit = try approvedWalletSigningPermitForTesting(
            approvedAccount: WalletAccountDescriptor(walletID: walletID, account: account)
        )
        let preparation = WalletSigningPreparation.fromSource(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)), walletsManager: manager
        )
        let signer = try XCTUnwrap(preparation.consume(permit: permit))
        let signing = Task { await signer.sign() }
        await fulfillment(of: [started], timeout: 2)

        signing.cancel()

        let credential = try XCTUnwrap(retainedCredential.withLock { $0 })
        XCTAssertFalse(credential.isAvailable)
        XCTAssertThrowsError(try credential.withUnsafeBytes { _ in XCTFail("Canceled source remained readable") })
        gate.resolve(())
        assertUnavailable(await signing.value)
        XCTAssertTrue(key.publicKeyData(coin: .ethereum).isEmpty)
    }

    func testFailedKeyDerivationRetiresItsOwnedSourceCredential() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: walletID)]
        reader.walletData = [walletID: Vectors.walletCoreJSONPrivateKeyFixture]
        reader.passwordData = Vectors.walletCoreJSONPrivateKeyPassword
        let retainedCredential = Mutex<SecretBytes?>(nil)
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching), keyDerivation: .init(derive: { source, _ in
            retainedCredential.withLock { $0 = source.password }
            throw WalletKeyStoreError.invalidPassword
        }))
        await assertWalletReload(manager)
        let account = try XCTUnwrap(manager.wallets.first?.accounts.first)
        let permit = try approvedWalletSigningPermitForTesting(
            approvedAccount: WalletAccountDescriptor(walletID: walletID, account: account)
        )
        let preparation = WalletSigningPreparation.fromSource(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)), walletsManager: manager
        )
        let signer = try XCTUnwrap(preparation.consume(permit: permit))

        guard case .failure(.failedToSign) = await signer.sign() else {
            return XCTFail("Expected the injected derivation failure")
        }

        let credential = try XCTUnwrap(retainedCredential.withLock { $0 })
        XCTAssertFalse(credential.isAvailable)
        XCTAssertThrowsError(try credential.withUnsafeBytes { _ in XCTFail("Failed derivation retained its source credential") })
    }

    func testPermissionRevocationDuringSigningDiscardsResult() async throws {
        let fixture = try ApprovedExecutionTestFixture()
        let permit = try sourceSigningPermit(in: fixture, account: descriptor())
        let signingStarted = expectation(description: "Signing started before revocation")
        let gate = TestGate<Void>()
        let backing = SigningProbe()
        backing.beforeReturn = {
            signingStarted.fulfill()
            await gate.wait()
        }
        let sessionPreparation = makeWalletSigningPreparationForTesting(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
            isCurrent: { true },
            sign: { operation, _ in await backing.sign(operation) },
            retireSigningMaterial: { backing.retireSigningMaterial() },
            commit: .native
        )
        let session = try XCTUnwrap(sessionPreparation.consume(permit: permit))
        let signing = Task { await session.sign() }
        await fulfillment(of: [signingStarted], timeout: 2)
        guard case .snapshot(let authority) = fixture.store.configurationSnapshot(
            configurationKey: "https://wallet.example", profileIdentifier: nil
        ), case .revoked = fixture.store.revoke(
            configurationKey: "https://wallet.example", provider: .ethereum,
            attempt: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            expected: authority.version, profileIdentifier: nil
        ) else {
            gate.resolve(())
            _ = await signing.value
            return XCTFail("Expected permission revocation while signing was suspended")
        }
        gate.resolve(())

        assertUnavailable(await signing.value)
        assertUnavailable(await session.sign())
        XCTAssertEqual(backing.operations.count, 1)
        XCTAssertEqual(backing.retirements, 1)
    }


    private func sourceSigningPermit(
        in fixture: ApprovedExecutionTestFixture,
        account: WalletAccountDescriptor
    ) throws -> ExtensionBridge.ApprovedExecutionPermit {
        try fixture.establishGrant(account)
        let snapshot = try fixture.enqueue(
            id: 1, name: "signPersonalMessage", provider: .ethereum,
            body: ["address": account.normalizedAddress, "chainId": "0x1", "object": ["data": "0x01"]]
        )
        let catalog = WalletReviewCatalog(
            identity: .init(generation: nil, catalogData: Data()), orderedAccounts: [account.specificAccount]
        )
        guard case .approval(let intent) = requestProcessorForTesting().prepare(try XCTUnwrap(snapshot.requestBinding), catalog: catalog) else {
            throw CocoaError(.coderInvalidValue)
        }
        let permit = try fixture.authorize(
            snapshot: snapshot, action: intent.action,
            decision: .message(.init(approvedAccount: account, solanaCluster: nil))
        )
        XCTAssertTrue(permit.consumeExecution())
        return permit
    }

    func testSourceSignerSignsOnceAndReturnsVerifiableSignature() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: walletID)]
        reader.walletData = [walletID: Vectors.walletCoreJSONPrivateKeyFixture]
        reader.passwordData = Vectors.walletCoreJSONPrivateKeyPassword
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        await assertWalletReload(manager)
        let account = try XCTUnwrap(manager.wallets.first?.accounts.first)
        let permit = try approvedWalletSigningPermitForTesting(
            approvedAccount: WalletAccountDescriptor(walletID: walletID, account: account)
        )
        let initialWalletReads = reader.walletReadCount
        let signerPreparation = WalletSigningPreparation.fromSource(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)), walletsManager: manager
        )
        XCTAssertTrue(signerPreparation.validateCurrent())
        XCTAssertEqual(reader.walletReadCount, initialWalletReads)
        XCTAssertEqual(reader.passwordReadCount, 0)
        let signer = try XCTUnwrap(signerPreparation.consume(permit: permit))
        XCTAssertEqual(reader.walletReadCount, initialWalletReads)
        XCTAssertEqual(reader.passwordReadCount, 0)
        try assertWalletSigningSuccessForTesting(await signer.sign(), permit: permit, account: account)
        XCTAssertGreaterThan(reader.walletReadCount, initialWalletReads)
        XCTAssertGreaterThan(reader.passwordReadCount, 0)
        let completedReads = reader.walletReadCount
        let completedPasswordReads = reader.passwordReadCount
        assertUnavailable(await signer.sign())
        XCTAssertEqual(reader.walletReadCount, completedReads)
        XCTAssertEqual(reader.passwordReadCount, completedPasswordReads)
    }

    func testSourceSignerRejectsWalletRemovalBeforeDerivationOrReturningSignature() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Vectors.walletCoreJSONPrivateKeyData))
        for walletRead in [1, 3] {
            let reader = KeychainCopyMatchingStub()
            reader.attributes = [reader.walletAttributes(id: walletID)]
            reader.walletData = [walletID: Vectors.walletCoreJSONPrivateKeyFixture]
            reader.passwordData = Vectors.walletCoreJSONPrivateKeyPassword
            let checking = expectation(description: "Source wallet read \(walletRead) started")
            let sourceCheck = WalletSigningSourceCheckGate(started: checking)
            defer { sourceCheck.release() }
            let walletKey = "org.lil.wallet.wallet.\(walletID)"
            let derivations = Mutex(0)
            let manager = WalletsManager(keychain: Keychain(copyMatching: { query, result in
                let attributes = query as NSDictionary
                if attributes[kSecAttrAccount as String] as? String == walletKey {
                    _ = sourceCheck.check()
                }
                return reader.copyMatching(query, result)
            }), keyDerivation: .init(derive: { _, _ in
                derivations.withLock { $0 += 1 }
                return key
            }))
            await assertWalletReload(manager)
            let account = try XCTUnwrap(manager.wallets.first?.accounts.first)
            let permit = try approvedWalletSigningPermitForTesting(
                approvedAccount: WalletAccountDescriptor(walletID: walletID, account: account)
            )
            let initialWalletReads = reader.walletReadCount
            let signerPreparation = WalletSigningPreparation.fromSource(
                scope: try XCTUnwrap(WalletSigningScope(permit: permit)), walletsManager: manager
            )
            let signer = try XCTUnwrap(signerPreparation.consume(permit: permit))
            sourceCheck.arm(check: walletRead)
            let signing = Task { await signer.sign() }
            await fulfillment(of: [checking], timeout: 2)
            reader.walletData[walletID] = nil
            sourceCheck.release()

            assertUnavailable(await signing.value)
            XCTAssertGreaterThan(reader.walletReadCount, initialWalletReads)
            XCTAssertEqual(reader.passwordReadCount > 0, walletRead == 3)
            XCTAssertEqual(derivations.withLock { $0 }, walletRead == 1 ? 0 : 1)
            let completedReads = reader.walletReadCount
            let completedPasswordReads = reader.passwordReadCount
            assertUnavailable(await signer.sign())
            XCTAssertEqual(reader.walletReadCount, completedReads)
            XCTAssertEqual(reader.passwordReadCount, completedPasswordReads)
        }
    }

    func testSourceSignerRejectsMissingAccountAndExpiredPermit() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.passwordData = Vectors.walletCoreJSONPrivateKeyPassword
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        let start = Date()
        let permit = try approvedWalletSigningPermitForTesting(approvedAccount: descriptor(), deadline: start)
        let expired = WalletSigningPreparation.fromSource(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)), walletsManager: manager, clock: { start }
        )
        XCTAssertNil(expired.consume(permit: permit))
        XCTAssertFalse(expired.validateCurrent())
        XCTAssertNil(expired.consume(permit: permit))
        let missingPermit = try approvedWalletSigningPermitForTesting(approvedAccount: descriptor())
        let missingPreparation = WalletSigningPreparation.fromSource(
            scope: try XCTUnwrap(WalletSigningScope(permit: missingPermit)), walletsManager: manager
        )
        let missing = try XCTUnwrap(missingPreparation.consume(permit: missingPermit))
        assertUnavailable(await missing.sign())
        XCTAssertEqual(reader.passwordReadCount, 0)
    }

    func testSigningAuthorizationRequiresPayloadCoinAndValidatedBroadcastCluster() throws {
        let solana = WalletAccountDescriptor(walletID: walletID, account: solanaAccount())
        let publicKey = try XCTUnwrap(WalletCrypto.base58Decode(string: solana.normalizedAddress))
        let message = SolanaMessageFixture.wireMessage(
            accountKeys: [publicKey], bodyAfterBlockhash: Data.encodeLength(0)
        )
        let encodedMessage = WalletCrypto.base58Encode(data: message)
        let transaction = try SolanaSigner().preparedTransactionMessageForSigning(
            message: encodedMessage, publicKey: solana.normalizedAddress
        ).get()
        let legacy = try SolanaSigner().preparedLegacySignAndSendTransaction(
            message: encodedMessage, publicKey: solana.normalizedAddress
        ).get()
        let serialized = try SolanaSigner().preparedSerializedTransactionForSignAndSend(
            serializedTransaction: WalletCrypto.base58Encode(data: Data([1]) + Data(repeating: 0, count: 64) + message),
            publicKey: solana.normalizedAddress
        ).get()
        let options = try SolanaSigner.preparedSendOptions(from: [:]).get()
        let cases: [(SignMessageAction.Payload, WalletCoin, Bool)] = [
            (.signature(.ethereumPersonalMessage(walletSigningTestMessage)), .ethereum, false),
            (.signature(.ethereumTypedData(Vectors.typedDataJSON)), .ethereum, false),
            (.signature(.solanaMessage(walletSigningTestMessage)), .solana, false),
            (.signature(.solanaTransaction(transaction)), .solana, false),
            (.signature(.solanaTransactions([transaction])), .solana, false),
            (.solanaLegacyBroadcast(legacy, options), .solana, true),
            (.solanaSerializedBroadcast(serialized, options), .solana, true),
        ]
        for approved in [descriptor(), solana] {
            let fixture = try ApprovedExecutionTestFixture()
            try fixture.establishGrant(approved)
            let snapshot = try fixture.enqueue(
                id: 1, name: approved.coin == .ethereum ? "signPersonalMessage" : "signMessage",
                provider: approved.coin == .ethereum ? .ethereum : .solana,
                body: approved.coin == .ethereum
                    ? ["address": approved.normalizedAddress, "chainId": "0x1", "object": ["data": "01"]]
                    : ["publicKey": approved.normalizedAddress, "object": ["params": ["message": "01"]]]
            )
            for (payload, coin, requiresCluster) in cases {
                for cluster: Solana.Cluster? in [nil, .devnet] {
                    let action = SignMessageAction(
                        subject: .signMessage, walletId: approved.walletID,
                        account: approved.account, meta: "", payload: payload,
                        solanaEndpoints: AuthorityTestSolanaEndpoints().snapshot
                    )
                    let result = DappApprovalValidator.resolve(
                        action: .approveMessage(action),
                        decision: .message(.init(approvedAccount: approved, solanaCluster: cluster)),
                        context: .init(
                            accounts: [.init(walletId: action.walletId, account: action.account)]
                        )
                    )
                    let validCluster = requiresCluster == (cluster != nil)
                    switch result {
                    case .success:
                        XCTAssertTrue(validCluster)
                        if approved.coin == coin {
                            let permit = try approvedWalletSigningPermitForTesting(
                                approvedAccount: approved, payload: payload
                            )
                            XCTAssertEqual(try XCTUnwrap(WalletSigningScope(permit: permit)).approvedAccount, approved)
                        } else {
                            let intent = try reviewIntentForTesting(
                                binding: XCTUnwrap(snapshot.requestBinding), action: .approveMessage(action)
                            )
                            guard case .approveMessage(let canonical) = intent.action else {
                                return XCTFail("Expected the canonical stored message")
                            }
                            XCTAssertEqual(canonical.payload.coin, approved.coin)
                            XCTAssertNotEqual(canonical.payload.coin, coin)
                        }
                    case .failure:
                        XCTAssertFalse(validCluster)
                    }
                }
            }
        }
    }

    func testEthereumSigningModesUseTheCapturedPayload() async throws {
        let cases: [(SignMessageAction.Payload, String)] = [
            (.signature(.ethereumPersonalMessage(Vectors.ethereumPersonalMessage)), Vectors.ethereumPersonalMessageSignature),
            (.signature(.ethereumTypedData(Vectors.typedDataJSON)), Vectors.ethereumTypedDataSignature),
        ]
        for (payload, expectedSignature) in cases {
            let (account, access) = try unlockedSigningAccess(coin: .ethereum, key: Vectors.ethereumSignerPrivateKey)
            let permit = try approvedWalletSigningPermitForTesting(approvedAccount: account, payload: payload)
            let signerPreparation = makeWalletSigningPreparationForTesting(
                scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
                isCurrent: { true },
                sign: { operation, source in await access.sign(operation, validating: source) },
                retireSigningMaterial: { access.invalidate() },
                commit: .native
            )
            let signer = try XCTUnwrap(signerPreparation.consume(permit: permit))
            let response = try walletSigningResponseForTesting(await signer.sign().get(), permit: permit)
            let signature = try XCTUnwrap(response.json["result"] as? String)
            XCTAssertEqual(signature, expectedSignature)
            assertUnavailable(await signer.sign())
        }
    }

    func testCryptographicFailureConsumesTheAttachedSigner() async throws {
        let (account, access) = try unlockedSigningAccess(coin: .ethereum, key: Vectors.ethereumSignerPrivateKey)
        let permit = try approvedWalletSigningPermitForTesting(
            approvedAccount: account, payload: .signature(.ethereumTypedData(Vectors.malformedTypedDataJSON))
        )
        let signerPreparation = makeWalletSigningPreparationForTesting(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
            isCurrent: { true },
            sign: { operation, source in await access.sign(operation, validating: source) },
            retireSigningMaterial: { access.invalidate() },
            commit: .native
        )
        let signer = try XCTUnwrap(signerPreparation.consume(permit: permit))
        guard case .failure(.failedToSign) = await signer.sign() else {
            return XCTFail("Expected malformed typed data to fail")
        }
        assertUnavailable(await signer.sign())
    }

    func testEthereumTransactionCapturesFinalNonceAndFees() async throws {
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
            final.replacePreparedFee(finalFee, provenance: original.feeProvenance)
            var parameters: [String: Any] = [
                "from": account.normalizedAddress,
                "to": "0x0000000000000000000000000000000000000002",
                "nonce": "0x0", "gas": "0x5208", "value": "0x1", "data": "0x",
            ]
            switch initialFee {
            case .legacy(let price):
                parameters["gasPrice"] = price.toHexString(withPrefix: true)
            case .eip1559(let priority, let maximum):
                parameters["maxPriorityFeePerGas"] = priority.toHexString(withPrefix: true)
                parameters["maxFeePerGas"] = maximum.toHexString(withPrefix: true)
            }
            let fixture = try ApprovedExecutionTestFixture()
            try fixture.establishGrant(account, network: network.network)
            let snapshot = try fixture.enqueue(
                id: 1, name: "signTransaction", provider: .ethereum,
                body: ["address": account.normalizedAddress, "chainId": "0xa", "object": parameters]
            )
            let action = SendTransactionAction(
                transaction: original, resolvedNetwork: network, walletId: account.walletID, account: account.account
            )
            let decision = try XCTUnwrap(DappApprovalDecision.TransactionExecution(
                final, reviewedNetwork: network, approvedAccount: account
            ))
            let permit = try fixture.authorize(
                snapshot: snapshot, action: .approveTransaction(action), decision: .transaction(decision)
            )
            XCTAssertTrue(permit.consumeExecution())
            let expected = try EthereumSigner.signedTransaction(
                transaction: final, privateKey: XCTUnwrap(WalletPrivateKey(data: Vectors.ethereumSignerPrivateKey)),
                network: network.network
            ).get()
            final.nonce = "0x8"
            let signerPreparation = makeWalletSigningPreparationForTesting(
                scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
                isCurrent: { true },
                sign: { operation, source in await access.sign(operation, validating: source) },
                retireSigningMaterial: { access.invalidate() },
                commit: .native
            )
            let signer = try XCTUnwrap(signerPreparation.consume(permit: permit))
            guard case .success(.broadcast(let output)) = await signer.sign(),
                  case .ethereum(let signed, let hash, _) = output.transaction else {
                return XCTFail("Expected signed Ethereum transaction")
            }
            XCTAssertEqual(signed, expected)
            XCTAssertEqual(hash, EthereumSigner.transactionHash(signedTransaction: expected))
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
            try SolanaSigner().preparedTransactionMessageForSigning(
                message: WalletCrypto.base58Encode(data: $0), publicKey: Vectors.solanaPreparedSignerPublicKey
            ).get()
        }
        let cases: [(SignMessageAction.Payload, [Data])] = [
            (.signature(.solanaMessage(walletSigningTestMessage)), [walletSigningTestMessage]),
            (.signature(.solanaTransaction(prepared[0])), [messages[0]]),
            (.signature(.solanaTransactions(prepared)), messages),
        ]
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        for (payload, expectedMessages) in cases {
            let (account, access) = try unlockedSigningAccess(coin: .solana, key: Vectors.solanaPreparedSignerPrivateKey)
            let permit = try approvedWalletSigningPermitForTesting(approvedAccount: account, payload: payload)
            let signerPreparation = makeWalletSigningPreparationForTesting(
                scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
                isCurrent: { true },
                sign: { operation, source in await access.sign(operation, validating: source) },
                retireSigningMaterial: { access.invalidate() },
                commit: .native
            )
            let signer = try XCTUnwrap(signerPreparation.consume(permit: permit))
            let signatures: [String]
            let value = try walletSigningResponseForTesting(await signer.sign().get(), permit: permit).json["result"]
            if let single = value as? String { signatures = [single] }
            else { signatures = try XCTUnwrap(value as? [String]) }
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
            var request = try XCTUnwrap(SafariRequest(json: [
                "id": 2, "name": "signAllTransactions", "provider": "solana",
                "host": "wallet.example", "configurationKey": "https://wallet.example",
                "enqueueAttempt": String(repeating: "a", count: 32),
                "admissionDeadline": Int(Date().addingTimeInterval(120).timeIntervalSince1970 * 1_000),
                "workflowVersion": ExtensionBridge.workflowVersion,
                "body": ["publicKey": account.normalizedAddress, "object": ["params": ["messages": messages]]],
            ]))
            request.authorizedAccount = account
            let binding = try requestBindingForTesting(request)
            guard case .immediate(let resolution) = requestProcessorForTesting().prepare(binding, catalog: catalog) else {
                return XCTFail("A malformed batch must not issue a partial signing approval")
            }
            let response = try XCTUnwrap(resolution.response(for: request))
            XCTAssertNotNil(response.json["error"])
            XCTAssertNil(response.json["result"])
        }
    }

    func testSolanaBroadcastPreservesCosignersAndSignaturePlacement() async throws {
        let signerPublicKey = try XCTUnwrap(WalletCrypto.base58Decode(string: Vectors.solanaPreparedSignerPublicKey))
        let cosigner = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 5, count: 32))
        let singleMessage = SolanaMessageFixture.wireMessage(accountKeys: [signerPublicKey], bodyAfterBlockhash: Data.encodeLength(0))
        let multiMessage = SolanaMessageFixture.wireMessage(
            requiredSignatures: 2, accountKeys: [cosigner.publicKey.rawRepresentation, signerPublicKey],
            bodyAfterBlockhash: Data.encodeLength(0)
        )
        let cosignerSignature = try cosigner.signature(for: multiMessage)
        let serialized = Data([2]) + cosignerSignature + Data(repeating: 0, count: 64) + multiMessage
        let legacy = try SolanaSigner().preparedLegacySignAndSendTransaction(
            message: WalletCrypto.base58Encode(data: singleMessage), publicKey: Vectors.solanaPreparedSignerPublicKey
        ).get()
        let prepared = try SolanaSigner().preparedSerializedTransactionForSignAndSend(
            serializedTransaction: WalletCrypto.base58Encode(data: serialized), publicKey: Vectors.solanaPreparedSignerPublicKey
        ).get()
        let options = try SolanaSigner.preparedSendOptions(from: [
            "maxRetries": 4, "minContextSlot": 42, "preflightCommitment": "confirmed"
        ]).get()
        let cases: [(SignMessageAction.Payload, Data, Int)] = [
            (.solanaLegacyBroadcast(legacy, options), singleMessage, 0),
            (.solanaSerializedBroadcast(prepared, options), multiMessage, 1),
        ]
        for (payload, message, signerIndex) in cases {
            let (account, access) = try unlockedSigningAccess(coin: .solana, key: Vectors.solanaPreparedSignerPrivateKey)
            let permit = try approvedWalletSigningPermitForTesting(
                approvedAccount: account, payload: payload,
                serializedTransaction: signerIndex == 1 ? WalletCrypto.base58Encode(data: serialized) : nil
            )
            let signerPreparation = makeWalletSigningPreparationForTesting(
                scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
                isCurrent: { true },
                sign: { operation, source in await access.sign(operation, validating: source) },
                retireSigningMaterial: { access.invalidate() },
                commit: .native
            )
            let signer = try XCTUnwrap(signerPreparation.consume(permit: permit))
            guard case .success(.broadcast(let output)) = await signer.sign(),
                  case .solana(let signed, let signature, _, _, _) = output.transaction else {
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
            assertUnavailable(await signer.sign())
        }
    }

    private func unlockedSigningAccess(coin: WalletCoin, key: Data) throws -> (WalletAccountDescriptor, UnlockedAccountSigner) {
        let password = Data("signing-tests".utf8)
        let storedKey = try XCTUnwrap(WalletStoredKey.importPrivateKey(privateKey: key, name: "Signer", password: password, coin: coin))
        let wallet = WalletContainer(id: walletID, key: storedKey)
        let account = try XCTUnwrap(wallet.accounts.first)
        let descriptor = WalletAccountDescriptor(walletID: walletID, account: account)
        let access = try XCTUnwrap(UnlockedAccountSigner(
            approvedAccount: descriptor,
            taking: wallet.privateKey(passwordData: password, account: account)
        ))
        return (descriptor, access)
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
        backing: SigningProbe,
        deadline: Date = .distantFuture,
        isCurrent: @escaping @Sendable () -> Bool = { true },
        clock: @escaping @MainActor @Sendable () -> Date = Date.init
    ) -> WalletSigningPreparation {
        makeWalletSigningPreparationForTesting(
            scope: walletSigningScopeForTesting(approvedAccount: approved, deadline: deadline),
            isCurrent: isCurrent,
            sign: { operation, _ in await backing.sign(operation) },
            retireSigningMaterial: { backing.retireSigningMaterial() },
            commit: .vault(acquire: { WalletExecutionLease {} }),
            clock: clock
        )
    }

    private func assertUnavailable(
        _ result: Result<WalletSigningOutput, WalletSigningFailure>,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(.authorizationUnavailable) = result else {
            return XCTFail("Expected unavailable signing authorization", file: file, line: line)
        }
    }

    @MainActor
    private final class SigningProbe {
        private nonisolated let invalidationCount = Mutex(0)
        var operations = [ApprovedWalletSigningOperation]()
        nonisolated var retirements: Int { invalidationCount.withLock { $0 } }
        var failure: WalletSigningFailure?
        var beforeReturn: (@MainActor () async -> Void)?

        @MainActor
        func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
            operations.append(operation)
            let result = failure.map { Result<WalletSigningOutput, WalletSigningFailure>.failure($0) } ?? walletSigningResultForTesting(operation)
            await beforeReturn?()
            return result
        }

        nonisolated func retireSigningMaterial() { invalidationCount.withLock { $0 += 1 } }
    }
}

#if os(iOS) || os(visionOS)
private final class WalletRemovalFixtureVaultKeys: SafariApprovalKeyStoring, SafariApprovalIntegrityKeyStoring, Sendable {
    func store(_ key: SecretBytes, identity: SafariApprovalKeyIdentity) throws {
        XCTFail("Source mutation fixture must not publish keys")
        throw SafariApprovalVault.Error.unavailable
    }
    func load(identity: SafariApprovalKeyIdentity, context: LAContext) throws -> SecretBytes {
        XCTFail("Source mutation fixture must not read keys")
        throw SafariApprovalVault.Error.unavailable
    }
    func availability(identities: [SafariApprovalKeyIdentity]) -> [SafariApprovalKeyIdentity: SafariApprovalKeyAvailability] {
        Dictionary(uniqueKeysWithValues: identities.map { ($0, .missing) })
    }
    func removeAll() throws {}
    func loadOrCreate() throws -> SecretBytes {
        XCTFail("Source mutation fixture must not create integrity keys")
        throw SafariApprovalVault.Error.unavailable
    }
}
#endif
