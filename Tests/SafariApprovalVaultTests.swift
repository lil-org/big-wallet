#if os(iOS) || os(visionOS)
import CryptoKit
import LocalAuthentication
import Security
import UIKit
import XCTest
@testable import Big_Wallet

final class SafariApprovalVaultTests: XCTestCase {

    private let integrityKey = Data(repeating: 0xa5, count: 32)

    private func fixture() throws -> (
        source: SafariApprovalSourceSnapshot,
        account: WalletAccount
    ) {
        let key = try XCTUnwrap(
            WalletStoredKey.importJSON(
                json: WalletCoreProxyTestVectors.walletCoreJSONPrivateKeyFixture
            )
        )
        let wallet = WalletContainer(id: "wallet", key: key)
        let account = try XCTUnwrap(wallet.accounts.first)
        let catalog = WalletAccountCatalog(
            accounts: WalletAccountCatalog(wallets: [wallet]).accounts
        )
        return (
            source: SafariApprovalSourceSnapshot(
                catalog: catalog,
                password: WalletCoreProxyTestVectors
                    .walletCoreJSONPrivateKeyPassword,
                wallets: [SafariApprovalWalletRecord(
                    walletID: wallet.id,
                    storedKeyJSON: WalletCoreProxyTestVectors
                        .walletCoreJSONPrivateKeyFixture
                )]
            ),
            account: account
        )
    }

    private func mnemonicFixture() throws -> (
        source: SafariApprovalSourceSnapshot,
        account: WalletAccount
    ) {
        let password = WalletCoreProxyTestVectors.walletCoreJSONMnemonicPassword
        let key = try XCTUnwrap(WalletStoredKey.importHDWallet(
            mnemonic: WalletCoreProxyTestVectors.walletCoreJSONMnemonic,
            name: "Mnemonic",
            password: password,
            coin: .ethereum
        ))
        let storedKeyJSON = try XCTUnwrap(key.exportJSON())
        let wallet = WalletContainer(id: "mnemonic-wallet", key: key)
        let account = try XCTUnwrap(wallet.accounts.first)
        return (
            source: SafariApprovalSourceSnapshot(
                catalog: WalletAccountCatalog(
                    accounts: WalletAccountCatalog(wallets: [wallet]).accounts
                ),
                password: password,
                wallets: [SafariApprovalWalletRecord(
                    walletID: wallet.id,
                    storedKeyJSON: storedKeyJSON
                )]
            ),
            account: account
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "SafariApprovalVaultTests-\(UUID().uuidString)"
        )
    }

    private func accountCountFixture(_ count: Int) throws -> SafariApprovalSourceSnapshot {
        let key = try XCTUnwrap(WalletStoredKey.importJSON(
            json: WalletCoreProxyTestVectors.walletCoreJSONVariantPrivateKeyFixtures[0].json
        ))
        let first = try XCTUnwrap(key.account(index: 0))
        for index in 1..<count {
            key.addAccountDerivation(
                address: first.address,
                coin: first.coin,
                derivation: .custom,
                derivationPath: "m/44'/60'/0'/0/\(index)",
                publicKey: first.publicKey,
                extendedPublicKey: ""
            )
        }
        let wallet = WalletContainer(id: "shared-signing-key", key: key)
        return SafariApprovalSourceSnapshot(
            catalog: WalletAccountCatalog(wallets: [wallet]),
            password: WalletCoreProxyTestVectors.walletCoreJSONPBKDF2PrivateKeyPassword,
            wallets: [SafariApprovalWalletRecord(
                walletID: wallet.id, storedKeyJSON: try XCTUnwrap(key.exportJSON())
            )]
        )
    }

    private struct AccountEnvelope: Codable {
        var account: WalletAccountDescriptor
        var nonce: Data
        var ciphertext: Data
        var tag: Data
    }

    private struct Envelope: Codable {
        let version: Int
        let generation: UUID
        let header: Data
        var catalog: Data
        var accounts: [AccountEnvelope]
    }

    private func readEnvelope(at url: URL) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
    }

    private func writeEnvelope(_ envelope: Envelope, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(envelope).write(to: url, options: .atomic)
    }

    private func accountAuthenticatedData(
        _ account: WalletAccountDescriptor,
        envelope: Envelope
    ) throws -> Data {
        struct AuthenticatedData: Encodable {
            let domain = "org.lil.wallet.safari-approval.account.v1"
            let header: Data
            let catalogDigest: Data
            let account: WalletAccountDescriptor
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(AuthenticatedData(
            header: envelope.header,
            catalogDigest: Data(SHA256.hash(data: envelope.catalog)),
            account: account
        ))
    }

    private func sealAccount(
        _ privateKey: Data,
        account: WalletAccountDescriptor,
        envelope: Envelope,
        key: Data
    ) throws -> AccountEnvelope {
        let sealed = try AES.GCM.seal(
            privateKey,
            using: SymmetricKey(data: key),
            authenticating: accountAuthenticatedData(account, envelope: envelope)
        )
        return AccountEnvelope(
            account: account,
            nonce: sealed.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
    }

    @MainActor
    private func assertSigningAccessForTesting(
        _ access: WalletSigningSession,
        walletID: String,
        account: WalletAccount,
        expectedSuccess: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let operation = try approvedWalletSigningOperationForTesting(
            approvedAccount: WalletAccountDescriptor(walletID: walletID, account: account),
            authorization: walletSigningAuthorizationForTesting(
                approvedAccount: WalletAccountDescriptor(walletID: walletID, account: account),
                handle: access.authorization.handle, deadline: access.authorization.signingDeadline
            )
        )
        guard access.bind(operation: operation, authorityIsCurrent: { _ in true }) else {
            XCTAssertFalse(expectedSuccess, "Expected authorization to bind", file: file, line: line)
            return
        }
        try assertSigningResultForTesting(await access.sign(), account: account, expectedSuccess: expectedSuccess, file: file, line: line)
    }

    private func assertSigningResultForTesting(
        _ result: Result<WalletSigningOutput, WalletSigningFailure>,
        account: WalletAccount,
        expectedSuccess: Bool,
        file: StaticString,
        line: UInt
    ) throws {
        if expectedSuccess {
            try assertWalletSigningSuccessForTesting(result, account: account, file: file, line: line)
        } else if case .success = result {
            XCTFail("Unexpected signing authorization", file: file, line: line)
        }
    }

    private func reformatStoredKey(in source: inout SafariApprovalSourceSnapshot) throws {
        let original = source.wallets[0].storedKeyJSON
        let object = try JSONSerialization.jsonObject(with: original)
        let reformatted = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        XCTAssertNotEqual(reformatted, original)
        source.wallets[0].storedKeyJSON = reformatted
    }

    private func orderedFixture() throws -> (
        source: SafariApprovalSourceSnapshot,
        accounts: [SpecificWalletAccount]
    ) {
        let password = WalletCoreProxyTestVectors.walletCoreJSONMnemonicPassword
        let mnemonicKey = try XCTUnwrap(WalletStoredKey.importHDWallet(
            mnemonic: WalletCoreProxyTestVectors.walletCoreJSONMnemonic,
            name: "Mnemonic",
            password: password,
            coin: .solana
        ))
        let solanaAccount = try XCTUnwrap(mnemonicKey.account(index: 0))
        let ethereumAccount = try XCTUnwrap(mnemonicKey.accountForCoin(
            coin: .ethereum,
            wallet: try XCTUnwrap(mnemonicKey.wallet(password: password))
        ))
        let privateKey = try XCTUnwrap(WalletStoredKey.importPrivateKey(
            privateKey: Data(repeating: 1, count: 32),
            name: "Imported",
            password: password,
            coin: .ethereum
        ))
        let importedAccount = try XCTUnwrap(privateKey.account(index: 0))
        let wallets = [
            WalletContainer(id: "z-wallet", key: mnemonicKey),
            WalletContainer(id: "a-wallet", key: privateKey),
        ]
        return (
            SafariApprovalSourceSnapshot(
                catalog: WalletAccountCatalog(
                    accounts: WalletAccountCatalog(wallets: wallets).accounts
                ),
                password: password,
                wallets: try wallets.map {
                    SafariApprovalWalletRecord(
                        walletID: $0.id,
                        storedKeyJSON: try XCTUnwrap($0.key.exportJSON())
                    )
                }
            ),
            [
                SpecificWalletAccount(walletId: "z-wallet", account: solanaAccount),
                SpecificWalletAccount(walletId: "z-wallet", account: ethereumAccount),
                SpecificWalletAccount(walletId: "a-wallet", account: importedAccount),
            ]
        )
    }

    func testCatalogIsPublicOnlyAndUnlockedReadReusesAuthenticationContext()
        async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var capabilityContext: LAContext?
        var authenticationContext: LAContext?
        var capabilityChecks = 0
        var authenticationAttempts = 0
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { context, policy in
                XCTAssertEqual(policy, .deviceOwnerAuthentication)
                capabilityChecks += 1
                capabilityContext = context
                return true
            },
            authentication: { context, policy, _ in
                XCTAssertEqual(policy, .deviceOwnerAuthentication)
                authenticationAttempts += 1
                authenticationContext = context
                return true
            },
            randomKey: { Data((0..<32).map(UInt8.init)) }
        )
        let fixture = try fixture()

        try vault.publish(
            source: fixture.source,
            integrityKey: integrityKey
        )
        let envelopeData = try Data(contentsOf: url)
        let envelopeText = try XCTUnwrap(
            String(data: envelopeData, encoding: .utf8)
        )
        XCTAssertFalse(envelopeText.contains("testpassword"))
        XCTAssertFalse(envelopeText.contains("encryptedPrivateKey"))
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: envelopeData) as? [String: Any]
        )
        XCTAssertEqual(Set(envelope.keys), [
            "accounts",
            "catalog",
            "generation",
            "header",
            "version",
        ])
        let sealedAccounts = try XCTUnwrap(envelope["accounts"] as? [[String: Any]])
        XCTAssertEqual(sealedAccounts.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(sealedAccounts.first).keys), [
            "account", "nonce", "ciphertext", "tag",
        ])
        XCTAssertEqual(envelope["version"] as? Int, 1)
        let catalogJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: (fixture.source.catalog).canonicalData()
            ) as? [String: Any]
        )
        let descriptors = try XCTUnwrap(
            catalogJSON["accounts"] as? [[String: Any]]
        )
        XCTAssertEqual(Set(try XCTUnwrap(descriptors.first).keys), [
            "coin",
            "derivationPath",
            "normalizedAddress",
            "walletID",
        ])
        let catalogAccess = try XCTUnwrap(vault.reviewCatalog())
        let originalCatalogData = try XCTUnwrap(Data(
            base64Encoded: XCTUnwrap(envelope["catalog"] as? String)
        ))
        XCTAssertEqual(
            catalogAccess.identity.catalogData,
            originalCatalogData
        )
        XCTAssertEqual(catalogAccess.orderedAccounts.count, 1)

        guard case .unlocked(let unlockedCatalog, let unlocked) = await vault.unlockResult(
            reason: "Approve",
            authorization: walletSigningAuthorizationForTesting(approvedAccount: WalletAccountDescriptor(walletID: "wallet", account: fixture.account))
        ) else {
            return XCTFail("Expected authenticated wallet catalog and signer")
        }
        XCTAssertEqual(capabilityChecks, 1)
        XCTAssertEqual(authenticationAttempts, 1)
        XCTAssertTrue(capabilityContext === authenticationContext)
        XCTAssertTrue(authenticationContext === keys.loadedContext)
        XCTAssertEqual(unlockedCatalog.identity, catalogAccess.identity)
        try await assertSigningAccessForTesting(unlocked, walletID: "wallet", account: fixture.account, expectedSuccess: true)
        unlocked.invalidate()
        try await assertSigningAccessForTesting(unlocked, walletID: "wallet", account: fixture.account, expectedSuccess: false)
    }

    func testPublishedAccountPayloadsContainOnlyTheirDerivedPrivateKeys() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try orderedFixture()
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
        try vault.publish(source: fixture.source, integrityKey: integrityKey)
        let envelope = try readEnvelope(at: url)
        let wallets = try XCTUnwrap(WalletSnapshotValidation.wallets(
            catalog: fixture.source.catalog,
            walletRecords: fixture.source.wallets.map { ($0.walletID, $0.storedKeyJSON) }
        ))

        XCTAssertEqual(envelope.accounts.map(\.account), fixture.source.catalog.accounts)
        XCTAssertEqual(Set(envelope.accounts.map(\.nonce)).count, envelope.accounts.count)
        XCTAssertEqual(keys.keys.count, envelope.accounts.count)
        XCTAssertEqual(Set(keys.keys.values).count, envelope.accounts.count)
        for entry in envelope.accounts {
            let identity = SafariApprovalKeyIdentity(generation: envelope.generation, account: entry.account)
            let key = SymmetricKey(data: try XCTUnwrap(keys.keys[identity]))
            XCTAssertEqual(entry.nonce.count, 12)
            XCTAssertEqual(entry.ciphertext.count, 32)
            XCTAssertEqual(entry.tag.count, 16)
            let sealed = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: entry.nonce),
                ciphertext: entry.ciphertext,
                tag: entry.tag
            )
            var plaintext = try AES.GCM.open(
                sealed,
                using: key,
                authenticating: accountAuthenticatedData(entry.account, envelope: envelope)
            )
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            XCTAssertEqual(plaintext.count, 32)
            let wallet = try XCTUnwrap(wallets.first { $0.id == entry.account.walletID })
            let expected = try wallet.privateKey(
                passwordData: fixture.source.password,
                account: entry.account.account
            )
            expected.withData { XCTAssertEqual(plaintext, $0) }
            for (otherIdentity, otherKey) in keys.keys where otherIdentity != identity {
                XCTAssertThrowsError(try AES.GCM.open(
                    sealed,
                    using: SymmetricKey(data: otherKey),
                    authenticating: accountAuthenticatedData(entry.account, envelope: envelope)
                ))
            }
        }
    }

    func testIndependentEncryptionKeysProtectIdenticalSigningKeys() throws {
        let source = try accountCountFixture(3)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
        try vault.publish(source: source, integrityKey: integrityKey)
        let envelope = try readEnvelope(at: url)
        XCTAssertEqual(keys.keys.count, 3)
        XCTAssertEqual(Set(keys.keys.values).count, 3)
        var plaintexts = Set<Data>()
        for entry in envelope.accounts {
            let identity = SafariApprovalKeyIdentity(generation: envelope.generation, account: entry.account)
            let sealed = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: entry.nonce), ciphertext: entry.ciphertext, tag: entry.tag
            )
            let aad = try accountAuthenticatedData(entry.account, envelope: envelope)
            for (candidate, key) in keys.keys {
                if candidate == identity {
                    plaintexts.insert(try AES.GCM.open(sealed, using: SymmetricKey(data: key), authenticating: aad))
                } else {
                    XCTAssertThrowsError(try AES.GCM.open(sealed, using: SymmetricKey(data: key), authenticating: aad))
                }
            }
        }
        XCTAssertEqual(plaintexts.count, 1)
        XCTAssertEqual(plaintexts.first?.count, 32)
    }

    func testMissingAccountKeysFilterCatalogAndSkipUnavailableAuthentication() async throws {
        let source = try accountCountFixture(3)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var authenticationAttempts = 0
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in authenticationAttempts += 1; return true }
        )
        let publication = try vault.publish(source: source, integrityKey: integrityKey)
        let original = try XCTUnwrap(vault.reviewCatalog())
        let identities = source.catalog.accounts.map {
            SafariApprovalKeyIdentity(generation: publication.generation, account: $0)
        }
        keys.keys.removeValue(forKey: identities[1])
        let available = try XCTUnwrap(vault.reviewCatalog())
        XCTAssertEqual(available.identity, original.identity)
        XCTAssertEqual(available.orderedAccounts, [source.catalog.accounts[0], source.catalog.accounts[2]].map(\.specificAccount))
        XCTAssertTrue(keys.loadedIdentities.isEmpty)
        guard case .unavailable = await vault.unlockResult(
            reason: "Missing", authorization: walletSigningAuthorizationForTesting(approvedAccount: identities[1].account)
        ) else { return XCTFail("A missing account key must fail before authentication") }
        XCTAssertEqual(authenticationAttempts, 0)
        XCTAssertTrue(keys.loadedIdentities.isEmpty)
        guard case .unlocked(let catalog, let signer) = await vault.unlockResult(
            reason: "Healthy", authorization: walletSigningAuthorizationForTesting(approvedAccount: identities[0].account)
        ) else { return XCTFail("Healthy accounts must remain available") }
        defer { signer.invalidate() }
        XCTAssertEqual(catalog.identity, original.identity)
        XCTAssertEqual(catalog.orderedAccounts, available.orderedAccounts)
        XCTAssertEqual(keys.loadedIdentities, [identities[0]])
        XCTAssertEqual(authenticationAttempts, 1)
        try await assertSigningAccessForTesting(
            signer, walletID: identities[0].account.walletID, account: identities[0].account.account, expectedSuccess: true
        )
        keys.keys.removeAll()
        XCTAssertNil(vault.reviewCatalog())
    }

    func testSiblingKeyLossAfterUnlockPreservesSigningAndCommitLease() async throws {
        let source = try accountCountFixture(3)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url, keyStore: keys,
            canEvaluateAuthentication: { _, _ in true }, authentication: { _, _, _ in true }
        )
        let publication = try vault.publish(source: source, integrityKey: integrityKey)
        let selected = source.catalog.accounts[0]
        guard case .unlocked(_, let signer) = await vault.unlockResult(
            reason: "Approve", authorization: walletSigningAuthorizationForTesting(approvedAccount: selected)
        ) else { return XCTFail("Expected selected signer") }
        defer { signer.invalidate() }
        keys.keys.removeValue(forKey: SafariApprovalKeyIdentity(
            generation: publication.generation, account: source.catalog.accounts[1]
        ))
        keys.availabilityRequests.removeAll()
        XCTAssertTrue(signer.validateCurrent())
        try await assertSigningAccessForTesting(signer, walletID: selected.walletID, account: selected.account, expectedSuccess: true)
        let acquired = await signer.takeCommitLease()
        let lease = try XCTUnwrap(acquired)
        lease.release()
        let identity = SafariApprovalKeyIdentity(generation: publication.generation, account: selected)
        XCTAssertTrue(keys.availabilityRequests.allSatisfy { $0 == [identity] })
        XCTAssertEqual(keys.loadedIdentities, [identity])
    }

    func testSelectedKeyLossRejectsSigningAndCommitLease() async throws {
        let source = try accountCountFixture(2)
        for alreadySigned in [false, true] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let keys = MemoryApprovalKeyStore()
            let vault = SafariApprovalVault(
                fileURL: url, keyStore: keys,
                canEvaluateAuthentication: { _, _ in true }, authentication: { _, _, _ in true }
            )
            let publication = try vault.publish(source: source, integrityKey: integrityKey)
            let selected = source.catalog.accounts[0]
            guard case .unlocked(_, let signer) = await vault.unlockResult(
                reason: "Approve", authorization: walletSigningAuthorizationForTesting(approvedAccount: selected)
            ) else { return XCTFail("Expected selected signer") }
            defer { signer.invalidate() }
            if alreadySigned {
                try await assertSigningAccessForTesting(signer, walletID: selected.walletID, account: selected.account, expectedSuccess: true)
            }
            keys.keys.removeValue(forKey: SafariApprovalKeyIdentity(generation: publication.generation, account: selected))
            XCTAssertFalse(signer.validateCurrent())
            if !alreadySigned {
                try await assertSigningAccessForTesting(signer, walletID: selected.walletID, account: selected.account, expectedSuccess: false)
            }
            let lease = await signer.takeCommitLease()
            XCTAssertNil(lease)
            XCTAssertEqual(vault.reviewCatalog()?.orderedAccounts, [source.catalog.accounts[1].specificAccount])
        }
    }

    func testSelectedKeyLossDuringAuthenticationLeavesSiblingAvailable() async throws {
        let source = try accountCountFixture(2)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var selectedIdentity: SafariApprovalKeyIdentity?
        let vault = SafariApprovalVault(
            fileURL: url, keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in
                if let selectedIdentity { keys.keys.removeValue(forKey: selectedIdentity) }
                return true
            }
        )
        let publication = try vault.publish(source: source, integrityKey: integrityKey)
        selectedIdentity = SafariApprovalKeyIdentity(generation: publication.generation, account: source.catalog.accounts[0])
        guard case .unavailable = await vault.unlockResult(
            reason: "Approve", authorization: walletSigningAuthorizationForTesting(approvedAccount: source.catalog.accounts[0])
        ) else { return XCTFail("A deleted account key must not yield a signer") }
        XCTAssertEqual(vault.reviewCatalog()?.orderedAccounts, [source.catalog.accounts[1].specificAccount])
    }

    func testEmptyPublicationNeedsNoAccountKeysOrKeychainReads() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url, keyStore: keys,
            randomKey: { XCTFail("Empty catalogs do not need encryption keys"); return Data() }
        )
        let source = SafariApprovalSourceSnapshot(
            catalog: WalletAccountCatalog(accounts: []), password: Data("empty-wallet".utf8), wallets: []
        )
        let publication = try vault.publish(source: source, integrityKey: integrityKey)
        let catalog = try XCTUnwrap(vault.reviewCatalog())
        XCTAssertTrue(catalog.orderedAccounts.isEmpty)
        XCTAssertTrue(keys.keys.isEmpty)
        XCTAssertTrue(keys.loadedIdentities.isEmpty)
        XCTAssertTrue(keys.availabilityRequests.allSatisfy(\.isEmpty))
        XCTAssertEqual(vault.publicationStatus(
            source: source, expectedGeneration: publication.generation,
            expectedEnvelopeDigest: publication.envelopeDigest, expectedSourceMAC: publication.sourceMAC,
            integrityKey: integrityKey
        ), .current)
    }

    func testUnlockIgnoresUnrelatedCorruptedAccountCiphertexts() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try orderedFixture()
        let keys = MemoryApprovalKeyStore()
        var protectedReads = 0
        keys.onLoad = { protectedReads += 1 }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true }
        )
        try vault.publish(source: fixture.source, integrityKey: integrityKey)
        let original = try readEnvelope(at: url)
        for selectedIndex in original.accounts.indices {
            var envelope = original
            for index in envelope.accounts.indices where index != selectedIndex {
                envelope.accounts[index].tag[0] ^= 0xff
            }
            try writeEnvelope(envelope, at: url)
            let selected = envelope.accounts[selectedIndex].account
            guard case .unlocked(let catalog, let signer) = await vault.unlockResult(
                reason: "Approve",
                authorization: walletSigningAuthorizationForTesting(approvedAccount: selected)
            ) else {
                return XCTFail("Unrelated account ciphertexts must not be decrypted")
            }
            XCTAssertEqual(catalog.orderedAccounts, fixture.source.catalog.accounts.map(\.specificAccount))
            XCTAssertEqual(protectedReads, selectedIndex + 1)
            try await assertSigningAccessForTesting(
                signer,
                walletID: selected.walletID,
                account: selected.account,
                expectedSuccess: true
            )
            signer.invalidate()
        }
    }

    func testMalformedAccountRecordsFailBeforeAuthentication() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try orderedFixture()
        let keys = MemoryApprovalKeyStore()
        var authenticationChecks = 0
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in
                authenticationChecks += 1
                return true
            },
            authentication: { _, _, _ in
                XCTFail("Malformed records must fail before authentication")
                return true
            }
        )
        try vault.publish(source: fixture.source, integrityKey: integrityKey)
        let original = try readEnvelope(at: url)
        let selected = try XCTUnwrap(fixture.source.catalog.accounts.first)
        let mutations: [(String, (inout Envelope) -> Void)] = [
            ("missing record", { $0.accounts.removeLast() }),
            ("extra record", { $0.accounts.append($0.accounts[0]) }),
            ("reordered records", { $0.accounts.swapAt(0, 1) }),
            ("duplicate identity", { $0.accounts[0].account = $0.accounts[1].account }),
            ("unknown identity", {
                $0.accounts[0].account = WalletAccountDescriptor(
                    walletID: "unknown-wallet", account: $0.accounts[0].account.account
                )
            }),
            ("reused nonce", { $0.accounts[0].nonce = $0.accounts[1].nonce }),
            ("short nonce", { $0.accounts[0].nonce.removeLast() }),
            ("long nonce", { $0.accounts[0].nonce.append(0) }),
            ("empty ciphertext", { $0.accounts[0].ciphertext = Data() }),
            ("short ciphertext", { $0.accounts[0].ciphertext.removeLast() }),
            ("long ciphertext", { $0.accounts[0].ciphertext.append(0) }),
            ("short tag", { $0.accounts[0].tag.removeLast() }),
            ("long tag", { $0.accounts[0].tag.append(0) }),
        ]
        for (name, mutate) in mutations {
            var envelope = original
            mutate(&envelope)
            try writeEnvelope(envelope, at: url)
            XCTAssertNil(vault.reviewCatalog(), name)
            guard case .unavailable = await vault.unlockResult(
                reason: "Approve",
                authorization: walletSigningAuthorizationForTesting(approvedAccount: selected)
            ) else {
                return XCTFail("Malformed record accepted: \(name)")
            }
        }
        XCTAssertEqual(authenticationChecks, 0)
        XCTAssertNil(keys.loadedContext)
    }

    func testSwappedAccountCiphertextsFailAuthenticatedUnlock() async throws {
        let original = try fixture().source
        let originalAccount = try XCTUnwrap(original.catalog.accounts.first)
        let originalWallet = try XCTUnwrap(original.wallets.first)
        let duplicateAccount = WalletAccountDescriptor(
            walletID: "duplicate-wallet", account: originalAccount.account
        )
        let duplicateKeySource = SafariApprovalSourceSnapshot(
            catalog: WalletAccountCatalog(accounts: [originalAccount, duplicateAccount]),
            password: original.password,
            wallets: [originalWallet, SafariApprovalWalletRecord(
                walletID: duplicateAccount.walletID,
                storedKeyJSON: originalWallet.storedKeyJSON
            )]
        )
        for source in [try orderedFixture().source, duplicateKeySource] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let keys = MemoryApprovalKeyStore()
            let vault = SafariApprovalVault(
                fileURL: url,
                keyStore: keys,
                canEvaluateAuthentication: { _, _ in true },
                authentication: { _, _, _ in true }
            )
            try vault.publish(source: source, integrityKey: integrityKey)
            var envelope = try readEnvelope(at: url)
            let first = envelope.accounts[0]
            let second = envelope.accounts[1]
            envelope.accounts[0] = AccountEnvelope(
                account: first.account,
                nonce: second.nonce,
                ciphertext: second.ciphertext,
                tag: second.tag
            )
            envelope.accounts[1] = AccountEnvelope(
                account: second.account,
                nonce: first.nonce,
                ciphertext: first.ciphertext,
                tag: first.tag
            )
            try writeEnvelope(envelope, at: url)
            XCTAssertNotNil(vault.reviewCatalog())
            for selected in [first.account, second.account] {
                guard case .unavailable = await vault.unlockResult(
                    reason: "Approve",
                    authorization: walletSigningAuthorizationForTesting(approvedAccount: selected)
                ) else {
                    return XCTFail("Ciphertext must be bound to its exact approved account")
                }
            }
            XCTAssertNotNil(keys.loadedContext)
        }
    }

    func testHeaderTamperingFailsAuthenticatedUnlock() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 9, count: 32) }
        )
        try vault.publish(
            source: fixture().source,
            integrityKey: integrityKey
        )

        let data = try Data(contentsOf: url)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let originalGeneration = try XCTUnwrap(
            UUID(uuidString: try XCTUnwrap(object["generation"] as? String))
        )
        let replacementGeneration = UUID()
        let account = try XCTUnwrap(fixture().source.catalog.accounts.first)
        let originalIdentity = SafariApprovalKeyIdentity(generation: originalGeneration, account: account)
        let replacementIdentity = SafariApprovalKeyIdentity(generation: replacementGeneration, account: account)
        keys.keys[replacementIdentity] = try XCTUnwrap(keys.keys[originalIdentity])
        let headerData = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(object["header"] as? String))
        )
        var header = try XCTUnwrap(
            JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        )
        header["generation"] = replacementGeneration.uuidString
        object["generation"] = replacementGeneration.uuidString
        object["header"] = try JSONSerialization.data(
            withJSONObject: header,
            options: [.sortedKeys]
        ).base64EncodedString()
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url, options: .atomic)

        XCTAssertEqual(vault.reviewCatalog()?.identity.generation, replacementGeneration)
        var loadedKey = false
        keys.onLoad = { loadedKey = true }
        let unlocked = await vault.unlockSignerForTesting(reason: "Approve")
        XCTAssertTrue(loadedKey)
        XCTAssertNil(unlocked)
    }

    func testUnlockAcceptsMatchingMnemonicAccountOwnership() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: MemoryApprovalKeyStore(),
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 19, count: 32) }
        )
        let fixture = try mnemonicFixture()
        try vault.publish(
            source: fixture.source,
            integrityKey: integrityKey
        )

        let unlockedValue = await vault.unlockSignerForTesting(reason: "Approve")
        let unlocked = try XCTUnwrap(unlockedValue)

        try await assertSigningAccessForTesting(unlocked, walletID: "mnemonic-wallet", account: fixture.account, expectedSuccess: true)
    }

    func testPublicationAndSelectedSignerRejectUnownedMnemonicAccount() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var publicationEvents = [String]()
        keys.onStore = { _ in publicationEvents.append("store") }
        keys.onRemove = { publicationEvents.append("remove") }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: {
                publicationEvents.append("random-key")
                return Data(repeating: 20, count: 32)
            },
            atomicWrite: { data, destination in
                publicationEvents.append("write")
                try data.write(to: destination, options: .atomic)
            }
        )
        let fixture = try mnemonicFixture()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: fixture.source.wallets[0].storedKeyJSON
            ) as? [String: Any]
        )
        var accounts = try XCTUnwrap(
            object["activeAccounts"] as? [[String: Any]]
        )
        accounts[0]["address"] =
            "0x0000000000000000000000000000000000000001"
        object["activeAccounts"] = accounts
        object["address"] = accounts[0]["address"]
        let storedKeyJSON = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let key = try XCTUnwrap(WalletStoredKey.importJSON(json: storedKeyJSON))
        let wallet = WalletContainer(id: "mnemonic-wallet", key: key)
        let source = SafariApprovalSourceSnapshot(
            catalog: WalletAccountCatalog(
                accounts: WalletAccountCatalog(wallets: [wallet]).accounts
            ),
            password: fixture.source.password,
            wallets: [SafariApprovalWalletRecord(
                walletID: wallet.id,
                storedKeyJSON: storedKeyJSON
            )]
        )
        XCTAssertThrowsError(try vault.publish(
            source: source,
            integrityKey: integrityKey
        )) { error in
            XCTAssertEqual(error as? SafariApprovalVault.Error, .invalidCatalog)
        }
        XCTAssertTrue(publicationEvents.allSatisfy { $0 == "random-key" })
        XCTAssertTrue(keys.keys.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try vault.publish(source: fixture.source, integrityKey: integrityKey)
        var envelope = try readEnvelope(at: url)
        envelope.catalog = try source.catalog.canonicalData()
        let originalWallet = WalletContainer(
            id: "mnemonic-wallet",
            key: try XCTUnwrap(WalletStoredKey.importJSON(json: fixture.source.wallets[0].storedKeyJSON))
        )
        let privateKey = try originalWallet.privateKey(
            passwordData: fixture.source.password,
            account: fixture.account
        )
        let originalIdentity = SafariApprovalKeyIdentity(
            generation: envelope.generation,
            account: try XCTUnwrap(fixture.source.catalog.accounts.first)
        )
        let replacementIdentity = SafariApprovalKeyIdentity(
            generation: envelope.generation,
            account: try XCTUnwrap(source.catalog.accounts.first)
        )
        keys.keys[replacementIdentity] = try XCTUnwrap(keys.keys[originalIdentity])
        envelope.accounts[0] = try privateKey.withData {
            try sealAccount(
                $0,
                account: XCTUnwrap(source.catalog.accounts.first),
                envelope: envelope,
                key: XCTUnwrap(keys.keys[replacementIdentity])
            )
        }
        try writeEnvelope(envelope, at: url)
        XCTAssertNotNil(vault.reviewCatalog())
        guard case .unavailable = await vault.unlockResult(
            reason: "Approve",
            authorization: walletSigningAuthorizationForTesting(
                approvedAccount: try XCTUnwrap(source.catalog.accounts.first)
            )
        ) else {
            return XCTFail("An unowned selected account must fail during unlock")
        }
        XCTAssertNotNil(keys.loadedContext)
    }

    func testVaultUnlockBindsEthereumAndSolanaSignersToSelectedIdentity()
        async throws {
        let fixture = try orderedFixture()
        let importedSolanaKey = try XCTUnwrap(WalletStoredKey.importPrivateKey(
            privateKey: Data(repeating: 2, count: 32),
            name: "Imported Solana",
            password: fixture.source.password,
            coin: .solana
        ))
        let importedSolanaWallet = WalletContainer(
            id: "imported-solana",
            key: importedSolanaKey
        )
        let source = SafariApprovalSourceSnapshot(
            catalog: WalletAccountCatalog(
                accounts: fixture.source.catalog.accounts +
                    WalletAccountCatalog(wallets: [importedSolanaWallet]).accounts
            ),
            password: fixture.source.password,
            wallets: fixture.source.wallets + [SafariApprovalWalletRecord(
                walletID: importedSolanaWallet.id,
                storedKeyJSON: try XCTUnwrap(importedSolanaKey.exportJSON())
            )]
        )
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: MemoryApprovalKeyStore(),
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true }
        )
        try vault.publish(source: source, integrityKey: integrityKey)
        let unlockedCatalog = try XCTUnwrap(vault.reviewCatalog())
        XCTAssertEqual(unlockedCatalog.orderedAccounts.count, 4)

        for selected in unlockedCatalog.orderedAccounts {
            let account = selected.account
            guard case .unlocked(_, let access) = await vault.unlockResult(
                reason: "Approve",
                authorization: walletSigningAuthorizationForTesting(approvedAccount: WalletAccountDescriptor(walletID: selected.walletId, account: account))
            ) else {
                return XCTFail("Expected selected account to unlock")
            }
            defer { access.invalidate() }
            try await assertSigningAccessForTesting(access, walletID: "missing-wallet", account: account, expectedSuccess: false)
            let otherWallet = try XCTUnwrap(unlockedCatalog.orderedAccounts.first {
                $0.walletId != selected.walletId
            })
            try await assertSigningAccessForTesting(access, walletID: otherWallet.walletId, account: account, expectedSuccess: false)
            for other in unlockedCatalog.orderedAccounts where other != selected {
                try await assertSigningAccessForTesting(access, walletID: other.walletId, account: other.account, expectedSuccess: false)
            }

            let otherAddress = account.coin == .ethereum
                ? "0x0000000000000000000000000000000000000001"
                : WalletCrypto.base58Encode(Data(repeating: 3, count: 32))
            let otherCoin: WalletCoin = account.coin == .ethereum ? .solana : .ethereum
            let mismatches: [(String, WalletCoin, String)] = [
                (otherAddress, account.coin, account.derivationPath),
                (account.address, otherCoin, account.derivationPath),
                (account.address, account.coin, account.derivationPath + "/1"),
            ]
            for (address, coin, derivationPath) in mismatches {
                let mismatchedAccount = WalletAccount(
                    address: address,
                    coin: coin,
                    derivation: account.derivation,
                    derivationPath: derivationPath,
                    publicKey: account.publicKey,
                    extendedPublicKey: account.extendedPublicKey
                )
                let descriptor = WalletAccountDescriptor(walletID: selected.walletId, account: mismatchedAccount)
                if descriptor.isValid {
                    try await assertSigningAccessForTesting(access, walletID: selected.walletId, account: mismatchedAccount, expectedSuccess: false)
                }
            }
            try await assertSigningAccessForTesting(access, walletID: selected.walletId, account: account, expectedSuccess: true)
        }
    }

    func testUnlockRejectsInvalidOrAbsentApprovedAccountBeforeAuthentication() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var authenticationChecks = 0
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in
                authenticationChecks += 1
                return true
            },
            authentication: { _, _, _ in
                XCTFail("Unreviewed account must not reach authentication")
                return true
            }
        )
        let source = try fixture().source
        try vault.publish(source: source, integrityKey: integrityKey)
        let approvedAccount = try XCTUnwrap(source.catalog.accounts.first)
        let scopes = [
            WalletAccountDescriptor(walletID: "other-wallet", account: approvedAccount.account),
            WalletAccountDescriptor(
                walletID: approvedAccount.walletID,
                coin: approvedAccount.coin,
                normalizedAddress: approvedAccount.normalizedAddress,
                derivationPath: approvedAccount.derivationPath + "/1"
            ),
            WalletAccountDescriptor(
                walletID: approvedAccount.walletID,
                coin: approvedAccount.coin,
                normalizedAddress: "invalid-address",
                derivationPath: approvedAccount.derivationPath
            ),
        ]
        for scope in scopes {
            guard case .unavailable = await vault.unlockResult(
                reason: "Approve",
                authorization: walletSigningAuthorizationForTesting(approvedAccount: scope)
            ) else {
                return XCTFail("Unreviewed account must fail closed")
            }
        }
        XCTAssertEqual(authenticationChecks, 0)
        XCTAssertNil(keys.loadedContext)
    }

    func testPublicationRejectsUndecryptableSourceWallet() throws {
        let fixture = try fixture()
        let unrelatedKey = try XCTUnwrap(WalletStoredKey.importPrivateKey(
            privateKey: Data(repeating: 2, count: 32),
            name: "Unrelated",
            password: Data("unrelated-password".utf8),
            coin: .solana
        ))
        let unrelatedWallet = WalletContainer(id: "unrelated-wallet", key: unrelatedKey)
        let source = SafariApprovalSourceSnapshot(
            catalog: WalletAccountCatalog(
                accounts: fixture.source.catalog.accounts +
                    WalletAccountCatalog(wallets: [unrelatedWallet]).accounts
            ),
            password: fixture.source.password,
            wallets: fixture.source.wallets + [SafariApprovalWalletRecord(
                walletID: unrelatedWallet.id,
                storedKeyJSON: try XCTUnwrap(unrelatedKey.exportJSON())
            )]
        )
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true }
        )
        XCTAssertThrowsError(try vault.publish(source: source, integrityKey: integrityKey)) {
            XCTAssertEqual($0 as? SafariApprovalVault.Error, .invalidCatalog)
        }
        XCTAssertTrue(keys.keys.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPublicationRejectsUnownedMnemonicSibling() throws {
        let fixture = try orderedFixture()
        var records = fixture.source.wallets
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: records[0].storedKeyJSON) as? [String: Any]
        )
        var accounts = try XCTUnwrap(object["activeAccounts"] as? [[String: Any]])
        XCTAssertEqual(accounts[1]["coin"] as? UInt32, WalletCoin.ethereum.rawValue)
        accounts[1]["address"] = "0x0000000000000000000000000000000000000001"
        object["activeAccounts"] = accounts
        records[0].storedKeyJSON = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let wallets = try records.map { record in
            WalletContainer(
                id: record.walletID,
                key: try XCTUnwrap(WalletStoredKey.importJSON(json: record.storedKeyJSON))
            )
        }
        let source = SafariApprovalSourceSnapshot(
            catalog: WalletAccountCatalog(accounts: WalletAccountCatalog(wallets: wallets).accounts),
            password: fixture.source.password,
            wallets: records
        )
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true }
        )
        XCTAssertThrowsError(try vault.publish(source: source, integrityKey: integrityKey)) {
            XCTAssertEqual($0 as? SafariApprovalVault.Error, .invalidCatalog)
        }
        XCTAssertTrue(keys.keys.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAuthenticationCancellationDoesNotReadProtectedKey() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var capabilityChecks = 0
        var authenticationAttempts = 0
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, policy in
                XCTAssertEqual(policy, .deviceOwnerAuthentication)
                capabilityChecks += 1
                return true
            },
            authentication: { _, policy, _ in
                XCTAssertEqual(policy, .deviceOwnerAuthentication)
                authenticationAttempts += 1
                return false
            },
            randomKey: { Data(repeating: 3, count: 32) }
        )
        try vault.publish(
            source: fixture().source,
            integrityKey: integrityKey
        )

        let result = await vault.unlockResult(
            reason: "Approve",
            authorization: walletSigningAuthorizationForTesting(approvedAccount: try XCTUnwrap(fixture().source.catalog.accounts.first))
        )

        guard case .canceled = result else {
            return XCTFail("Authentication cancellation must remain distinct")
        }
        XCTAssertEqual(capabilityChecks, 1)
        XCTAssertEqual(authenticationAttempts, 1)
        XCTAssertNil(keys.loadedContext)
    }

    func testCancelledOrExpiredUnlockDoesNotAuthenticate() async throws {
        let fixture = try fixture()
        for cancel in [false, true] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let keys = MemoryApprovalKeyStore()
            let vault = SafariApprovalVault(
                fileURL: url,
                keyStore: keys,
                canEvaluateAuthentication: { _, _ in
                    XCTFail("An inactive authorization must not reach authentication")
                    return true
                },
                authentication: { _, _, _ in
                    XCTFail("An inactive authorization must not authenticate")
                    return true
                }
            )
            try vault.publish(source: fixture.source, integrityKey: integrityKey)
            let authorization = walletSigningAuthorizationForTesting(
                approvedAccount: try XCTUnwrap(fixture.source.catalog.accounts.first),
                deadline: cancel ? .distantFuture : .distantPast
            )
            let result = await Task {
                if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                return await vault.unlockResult(reason: "Approve", authorization: authorization)
            }.value

            guard case .unavailable = result else {
                return XCTFail("Cancellation or expiry must fail before authentication")
            }
            XCTAssertNil(keys.loadedContext)
        }
    }

    func testTaskCancellationAfterAuthenticationDoesNotReturnSession() async throws {
        let fixture = try fixture()
        for cancelDuringKeyRead in [false, true] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let keys = MemoryApprovalKeyStore()
            var authenticated = false
            let vault = SafariApprovalVault(
                fileURL: url,
                keyStore: keys,
                canEvaluateAuthentication: { _, _ in true },
                authentication: { _, _, _ in
                    authenticated = true
                    if !cancelDuringKeyRead { withUnsafeCurrentTask { $0?.cancel() } }
                    return true
                }
            )
            try vault.publish(source: fixture.source, integrityKey: integrityKey)
            if cancelDuringKeyRead {
                keys.onLoad = { withUnsafeCurrentTask { $0?.cancel() } }
            }
            let authorization = walletSigningAuthorizationForTesting(
                approvedAccount: try XCTUnwrap(fixture.source.catalog.accounts.first)
            )
            let result = await Task {
                await vault.unlockResult(reason: "Approve", authorization: authorization)
            }.value

            guard case .unavailable = result else {
                return XCTFail("A cancelled authenticated task must not return a signing session")
            }
            XCTAssertTrue(authenticated)
            XCTAssertEqual(keys.loadedContext != nil, cancelDuringKeyRead)
        }
    }

    func testAuthorizationExpiryDuringAuthenticationDoesNotReadProtectedKey() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try fixture()
        let keys = MemoryApprovalKeyStore()
        var deadline = Date.distantFuture
        var authenticated = false
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in
                authenticated = true
                while Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return true
            }
        )
        try vault.publish(source: fixture.source, integrityKey: integrityKey)
        deadline = Date().addingTimeInterval(1)
        let result = await vault.unlockResult(
            reason: "Approve",
            authorization: walletSigningAuthorizationForTesting(
                approvedAccount: try XCTUnwrap(fixture.source.catalog.accounts.first),
                deadline: deadline
            )
        )

        guard case .unavailable = result else {
            return XCTFail("Authentication must not revive an expired authorization")
        }
        XCTAssertTrue(authenticated)
        XCTAssertNil(keys.loadedContext)
    }

    func testUnlockRejectsEnvelopeRotatedDuringProtectedKeyRead() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let source = try fixture().source
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 5, count: 32) }
        )
        try vault.publish(
            source: source,
            integrityKey: integrityKey
        )
        let originalGeneration = try XCTUnwrap(vault.reviewCatalog()?.identity.generation)
        keys.onLoad = {
            keys.onLoad = nil
            _ = try? vault.publish(
                source: source,
                integrityKey: self.integrityKey
            )
        }

        let result = await vault.unlockResult(
            reason: "Approve",
            authorization: walletSigningAuthorizationForTesting(approvedAccount: try XCTUnwrap(source.catalog.accounts.first))
        )

        guard case .unavailable = result else {
            return XCTFail("A rotated envelope must invalidate the unlock")
        }
        let replacementGeneration = try XCTUnwrap(vault.reviewCatalog()?.identity.generation)
        XCTAssertNotEqual(replacementGeneration, originalGeneration)
    }

    func testCatalogAndUnlockedScopeRequireCurrentGenerationKey() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 6, count: 32) }
        )
        let fixture = try fixture()
        try vault.publish(
            source: fixture.source,
            integrityKey: integrityKey
        )
        let unlockedValue = await vault.unlockSignerForTesting(reason: "Approve")
        let unlocked = try XCTUnwrap(unlockedValue)
        let executionValue = await vault.unlockSignerForTesting(reason: "Approve")
        let execution = try XCTUnwrap(executionValue)

        try keys.removeAll()

        XCTAssertNil(vault.reviewCatalog())
        XCTAssertFalse(unlocked.validateCurrent())
        try await assertSigningAccessForTesting(unlocked, walletID: "wallet", account: fixture.account, expectedSuccess: false)
        let lease = await execution.takeCommitLease()
        XCTAssertNil(lease)
    }

    func testUnlockedScopesRequireUnchangedEnvelopeBytes() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: MemoryApprovalKeyStore(),
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 6, count: 32) }
        )
        let fixture = try fixture()
        try vault.publish(source: fixture.source, integrityKey: integrityKey)
        let unlockedValue = await vault.unlockSignerForTesting(reason: "Approve")
        let unlocked = try XCTUnwrap(unlockedValue)
        let executionValue = await vault.unlockSignerForTesting(reason: "Approve")
        let execution = try XCTUnwrap(executionValue)
        let originalData = try Data(contentsOf: url)

        try originalData.write(to: url, options: .atomic)

        XCTAssertTrue(unlocked.validateCurrent())
        try await assertSigningAccessForTesting(unlocked, walletID: "wallet", account: fixture.account, expectedSuccess: true)

        try (originalData + Data("\n".utf8)).write(to: url, options: .atomic)

        XCTAssertNotNil(vault.reviewCatalog())
        let replacement = await vault.unlockSignerForTesting(reason: "Approve")
        XCTAssertNotNil(replacement)
        XCTAssertFalse(unlocked.validateCurrent())
        try await assertSigningAccessForTesting(unlocked, walletID: "wallet", account: fixture.account, expectedSuccess: false)
        let lease = await execution.takeCommitLease()
        XCTAssertNil(lease)
    }

    func testRequestScopeRechecksGenerationAfterSigning() async throws {
        let fixture = try fixture()
        var isCurrent = true
        let underlying = DerivationRaceWalletSigner(account: fixture.account) {
            isCurrent = false
        }
        let scoped = makeWalletSigningSessionForTesting(
            underlying,
            authorization: walletSigningAuthorizationForTesting(approvedAccount: WalletAccountDescriptor(walletID: "wallet", account: fixture.account)),
            isCurrent: { isCurrent }
        )

        try await assertSigningAccessForTesting(scoped, walletID: "wallet", account: fixture.account, expectedSuccess: false)
        XCTAssertFalse(scoped.validateCurrent())
    }

    func testExecutionLeaseBlocksVaultTombstoneUntilReleased()
        async throws {
        let url = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(
                at: url.appendingPathExtension("coordination-lock")
            )
        }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: MemoryApprovalKeyStore(),
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 21, count: 32) }
        )
        try vault.publish(
            source: fixture().source,
            integrityKey: integrityKey
        )
        let unlocked = await vault.unlockSignerForTesting(reason: "Approve")
        let access = try XCTUnwrap(unlocked)
        let executionLeaseValue = await access.takeCommitLease()
        let executionLease = try XCTUnwrap(executionLeaseValue)
        let reusedLease = await access.takeCommitLease()
        XCTAssertNil(reusedLease)

        XCTAssertThrowsError(try vault.acquireCoordinationLease(
            timeoutNanoseconds: 1_000_000
        ))
        XCTAssertNotNil(vault.reviewCatalog())

        executionLease.release()
        try vault.markUnavailable()
        XCTAssertNil(vault.reviewCatalog())
    }

    @MainActor
    func testOverlappingExecutionLeasesAllowMainActorRelease() async throws {
        let url = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(
                at: url.appendingPathExtension("coordination-lock")
            )
        }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: MemoryApprovalKeyStore(),
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true }
        )
        try vault.publish(source: fixture().source, integrityKey: integrityKey)
        let firstAccess = await vault.unlockSignerForTesting(reason: "First approval")
        let secondAccess = await vault.unlockSignerForTesting(reason: "Second approval")
        let firstLeaseValue = await firstAccess?.takeCommitLease()
        let firstLease = try XCTUnwrap(firstLeaseValue)
        defer { firstLease.release() }
        let releaseTask = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(50))
            firstLease.release()
        }
        defer { releaseTask.cancel() }

        let secondLease = await secondAccess?.takeCommitLease()

        XCTAssertNotNil(secondLease)
        secondLease?.release()
        try await releaseTask.value
    }

    @MainActor
    func testExecutionLeaseIsReleasedWhenScopeEndsDuringAcquisition() async throws {
        let account = try fixture().account
        for cancel in [false, true] {
            let started = expectation(description: "Lease acquisition started")
            var continuation: CheckedContinuation<WalletExecutionLease?, Never>?
            let access = makeWalletSigningSessionForTesting(
                DerivationRaceWalletSigner(account: account) {},
                authorization: walletSigningAuthorizationForTesting(approvedAccount: WalletAccountDescriptor(walletID: "wallet", account: account)),
                acquireCommitLease: {
                    await withCheckedContinuation {
                        continuation = $0
                        started.fulfill()
                    }
                }
            )
            let acquisition = Task { await access.takeCommitLease() }
            await fulfillment(of: [started], timeout: 1)
            let finishAcquisition = try XCTUnwrap(continuation)
            if cancel {
                acquisition.cancel()
            } else {
                access.invalidate()
            }
            var released = false
            finishAcquisition.resume(returning: WalletExecutionLease { released = true })

            let lease = await acquisition.value

            XCTAssertNil(lease)
            XCTAssertTrue(released)
        }
    }

    func testExactCatalogBytesAreAuthenticated() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try orderedFixture()
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 8, count: 32) }
        )
        try vault.publish(source: fixture.source, integrityKey: integrityKey)
        var envelope = try readEnvelope(at: url)
        var accounts = fixture.source.catalog.accounts
        accounts[1] = WalletAccountDescriptor(
            walletID: "changed-wallet", account: accounts[1].account
        )
        envelope.catalog = try WalletAccountCatalog(accounts: accounts).canonicalData()
        envelope.accounts[1].account = accounts[1]
        try writeEnvelope(envelope, at: url)

        XCTAssertNotNil(vault.reviewCatalog())
        guard case .unavailable = await vault.unlockResult(
            reason: "Approve",
            authorization: walletSigningAuthorizationForTesting(approvedAccount: accounts[0])
        ) else {
            return XCTFail("A change to a sibling catalog entry must invalidate the selected ciphertext")
        }
        XCTAssertNotNil(keys.loadedContext)
    }

    func testValidatedCatalogRetainsCanonicalBytes() throws {
        let catalog = try fixture().source.catalog
        let data = try (catalog).canonicalData()
        let validated = try XCTUnwrap(ValidatedWalletAccountCatalog(data: data))

        XCTAssertEqual(validated.catalog, catalog)
        XCTAssertEqual(validated.data, data)
    }

    func testUnlockRejectsInvalidSelectedAccountPayloadBeforeReturningSession() async throws {
        for fixture in [try fixture(), try mnemonicFixture()] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let keys = MemoryApprovalKeyStore()
            let vault = SafariApprovalVault(
                fileURL: url,
                keyStore: keys,
                canEvaluateAuthentication: { _, _ in true },
                authentication: { _, _, _ in true }
            )
            try vault.publish(source: fixture.source, integrityKey: integrityKey)
            let original = try readEnvelope(at: url)
            let selected = try XCTUnwrap(fixture.source.catalog.accounts.first)
            for mutation in ["ciphertext", "tag", "zero private key", "wrong private key"] {
                var envelope = original
                switch mutation {
                case "ciphertext":
                    envelope.accounts[0].ciphertext[0] ^= 0xff
                case "tag":
                    envelope.accounts[0].tag[0] ^= 0xff
                default:
                    envelope.accounts[0] = try sealAccount(
                        Data(repeating: mutation == "zero private key" ? 0 : 0x8f, count: 32),
                        account: selected,
                        envelope: envelope,
                        key: XCTUnwrap(keys.keys[SafariApprovalKeyIdentity(
                            generation: envelope.generation, account: selected
                        )])
                    )
                }
                try writeEnvelope(envelope, at: url)
                XCTAssertNotNil(vault.reviewCatalog(), mutation)
                keys.loadedContext = nil
                guard case .unavailable = await vault.unlockResult(
                    reason: "Approve",
                    authorization: walletSigningAuthorizationForTesting(approvedAccount: selected)
                ) else {
                    return XCTFail("Invalid selected account payload accepted: \(mutation)")
                }
                XCTAssertNotNil(keys.loadedContext, mutation)
            }
        }
    }

    func testInvalidCatalogBytesFailBeforeAuthentication() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var authenticationChecks = 0
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in
                authenticationChecks += 1
                return true
            },
            authentication: { _, _, _ in
                XCTFail("An invalid catalog must not reach authentication")
                return true
            }
        )
        let source = try fixture().source
        try vault.publish(source: source, integrityKey: integrityKey)
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let descriptor = try XCTUnwrap(source.catalog.accounts.first)
        let invalidDescriptor = WalletAccountDescriptor(
            walletID: descriptor.walletID,
            coin: descriptor.coin,
            normalizedAddress: "invalid-address",
            derivationPath: descriptor.derivationPath
        )
        let canonicalData = try (source.catalog).canonicalData()
        var unknownCoin = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
        )
        var accounts = try XCTUnwrap(unknownCoin["accounts"] as? [[String: Any]])
        accounts[0]["coin"] = UInt32.max
        unknownCoin["accounts"] = accounts
        let invalidCatalogs = [
            Data(),
            Data("{".utf8),
            Data(#"{"accounts":[],"unexpected":true}"#.utf8),
            canonicalData + Data("\n".utf8),
            try JSONSerialization.data(withJSONObject: unknownCoin, options: [.sortedKeys]),
            try (WalletAccountCatalog(
                accounts: [invalidDescriptor]
            )).canonicalData(),
            try (WalletAccountCatalog(
                accounts: [descriptor, descriptor]
            )).canonicalData(),
        ]

        for data in invalidCatalogs {
            XCTAssertNil(ValidatedWalletAccountCatalog(data: data))
            envelope["catalog"] = data.base64EncodedString()
            try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
                .write(to: url, options: .atomic)

            XCTAssertNil(vault.reviewCatalog())
            guard case .unavailable = await vault.unlockResult(
                reason: "Approve",
                authorization: walletSigningAuthorizationForTesting(approvedAccount: descriptor)
            ) else {
                return XCTFail("An invalid catalog must make the vault unavailable")
            }
        }
        XCTAssertEqual(authenticationChecks, 0)
        XCTAssertNil(keys.loadedContext)
    }

    func testCatalogAndUnlockedAccessPreserveWalletAndAccountArrayOrder() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try orderedFixture()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: MemoryApprovalKeyStore(),
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true }
        )
        try vault.publish(
            source: fixture.source,
            integrityKey: integrityKey
        )

        let catalog = try XCTUnwrap(vault.reviewCatalog())
        XCTAssertEqual(catalog.orderedAccounts.map(\.walletId), [
            "z-wallet", "z-wallet", "a-wallet",
        ])
        XCTAssertEqual(catalog.orderedAccounts.map(\.account.coin), [
            .solana, .ethereum, .ethereum,
        ])
        XCTAssertEqual(
            catalog.orderedAccounts.map(\.account.address),
            fixture.accounts.map { $0.account.coin.normalizedAddress($0.account.address) }
        )
        XCTAssertEqual(
            catalog.orderedAccounts.map(\.account.derivationPath),
            fixture.accounts.map(\.account.derivationPath)
        )

        for selected in fixture.accounts {
            let approvedAccount = WalletAccountDescriptor(
                walletID: selected.walletId,
                account: selected.account
            )
            guard case .unlocked(let unlockedCatalog, let unlocked) = await vault.unlockResult(
                reason: "Approve",
                authorization: walletSigningAuthorizationForTesting(approvedAccount: approvedAccount)
            ) else {
                return XCTFail("Expected authenticated wallet catalog and signer")
            }
            defer { unlocked.invalidate() }
            XCTAssertEqual(unlockedCatalog.identity, catalog.identity)
            XCTAssertEqual(unlockedCatalog.orderedAccounts, catalog.orderedAccounts)
            XCTAssertEqual(unlocked.approvedAccount, approvedAccount)
            try await assertSigningAccessForTesting(unlocked, walletID: selected.walletId, account: selected.account, expectedSuccess: true)
            for other in fixture.accounts where other != selected {
                try await assertSigningAccessForTesting(unlocked, walletID: other.walletId, account: other.account, expectedSuccess: false)
            }
        }
    }

    func testReorderedCatalogBytesFailAuthenticatedUnlock() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try orderedFixture()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: MemoryApprovalKeyStore(),
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true }
        )
        try vault.publish(
            source: fixture.source,
            integrityKey: integrityKey
        )
        var envelope = try readEnvelope(at: url)
        let reordered = WalletAccountCatalog(
            accounts: Array(fixture.source.catalog.accounts.reversed())
        )
        XCTAssertTrue(reordered.isValid)
        envelope.catalog = try reordered.canonicalData()
        envelope.accounts.reverse()
        try writeEnvelope(envelope, at: url)

        XCTAssertNotNil(vault.reviewCatalog())
        let unlocked = await vault.unlockSignerForTesting(reason: "Approve")
        XCTAssertNil(unlocked)
    }

    func testPublicationRejectsCatalogOrderThatDiffersFromWalletRecords() throws {
        let fixture = try orderedFixture()
        for order in [[1, 0, 2], [2, 0, 1]] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let catalog = WalletAccountCatalog(
                accounts: order.map { fixture.source.catalog.accounts[$0] }
            )
            let source = SafariApprovalSourceSnapshot(
                catalog: catalog,
                password: fixture.source.password,
                wallets: fixture.source.wallets
            )
            let keys = MemoryApprovalKeyStore()
            let vault = SafariApprovalVault(
                fileURL: url,
                keyStore: keys,
                canEvaluateAuthentication: { _, _ in true },
                authentication: { _, _, _ in true }
            )
            XCTAssertThrowsError(try vault.publish(
                source: source,
                integrityKey: integrityKey
            )) { error in
                XCTAssertEqual(error as? SafariApprovalVault.Error, .invalidCatalog)
            }
            XCTAssertTrue(keys.keys.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNil(WalletSnapshotValidation.wallets(
                catalog: source.catalog,
                walletRecords: source.wallets.map {
                    (id: $0.walletID, data: $0.storedKeyJSON)
                }
            ))
        }
    }

    func testEnvelopeCapFailsClosedBeforeKeyPublication() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 1, count: 32) }
        )
        var source = try fixture().source
        source.password = Data(
            repeating: 1,
            count: SafariApprovalVault.maximumEnvelopeBytes
        )

        XCTAssertThrowsError(try vault.publish(
            source: source,
            integrityKey: integrityKey
        )) { error in
            XCTAssertEqual(error as? SafariApprovalVault.Error, .payloadTooLarge)
        }
        XCTAssertTrue(keys.keys.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testEnvelopeReadRejectsSymbolicLink() throws {
        let targetURL = temporaryURL()
        let linkURL = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: linkURL)
            try? FileManager.default.removeItem(at: targetURL)
            try? FileManager.default.removeItem(
                at: targetURL.appendingPathExtension("coordination-lock")
            )
        }
        let keys = MemoryApprovalKeyStore()
        let publisher = SafariApprovalVault(
            fileURL: targetURL,
            keyStore: keys,
            randomKey: { Data(repeating: 22, count: 32) }
        )
        try publisher.publish(
            source: fixture().source,
            integrityKey: integrityKey
        )
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )
        let reader = SafariApprovalVault(
            fileURL: linkURL,
            keyStore: keys
        )

        XCTAssertNil(reader.reviewCatalog())
    }

    func testEnvelopeReadRejectsOversizedSparseRegularFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.path,
            contents: nil
        ))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(
            atOffset: UInt64(SafariApprovalVault.maximumEnvelopeBytes + 1)
        )
        try handle.close()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: MemoryApprovalKeyStore()
        )

        XCTAssertNil(vault.reviewCatalog())
    }

    func testKeychainQueriesUseProtectedApprovalGroupAndExactContext() throws {
        let generation = UUID()
        let identity = SafariApprovalKeyIdentity(
            generation: generation, account: try XCTUnwrap(fixture().source.catalog.accounts.first)
        )
        let context = LAContext()
        let query = try SafariApprovalKeychainStore.loadQuery(
            identity: identity,
            context: context
        )

        XCTAssertEqual(
            query[kSecAttrAccessGroup as String] as? String,
            "8DXC3N7E7P.org.lil.wallet.safari-approval"
        )
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(
            query[kSecAttrAccount as String] as? String,
            try identity.keychainAccount()
        )
        XCTAssertTrue(
            query[kSecUseAuthenticationContext as String] as AnyObject === context
        )
        XCTAssertEqual(
            SafariApprovalKeychainStore.accessibility,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        )
        XCTAssertEqual(
            SafariApprovalKeychainStore.accessControlFlags,
            .userPresence
        )

        let integrityStoreQuery =
            SafariApprovalIntegrityKeychainStore.storeQuery(integrityKey)
        XCTAssertEqual(
            integrityStoreQuery[kSecAttrAccessGroup as String] as? String,
            "8DXC3N7E7P.org.lil.keychain"
        )
        XCTAssertEqual(
            integrityStoreQuery[kSecAttrService as String] as? String,
            "org.lil.wallet.safari-approval-integrity.v1"
        )
        XCTAssertEqual(
            integrityStoreQuery[kSecAttrAccount as String] as? String,
            "source-snapshot-hmac"
        )
        XCTAssertEqual(
            integrityStoreQuery[kSecUseDataProtectionKeychain as String] as? Bool,
            true
        )
        XCTAssertEqual(
            integrityStoreQuery[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(
            integrityStoreQuery[kSecValueData as String] as? Data,
            integrityKey
        )
        XCTAssertNil(
            integrityStoreQuery[kSecAttrAccessControl as String]
        )
        XCTAssertEqual(
            Set(SafariApprovalIntegrityKeychainStore.loadQuery.keys),
            Set(SafariApprovalIntegrityKeychainStore.baseQuery.keys).union([
                kSecReturnData as String,
                kSecMatchLimit as String,
            ])
        )
    }

    func testKeyAvailabilityMapsProductionStatusesWithoutAuthentication() throws {
        let generation = UUID()
        let identity = SafariApprovalKeyIdentity(
            generation: generation, account: try XCTUnwrap(fixture().source.catalog.accounts.first)
        )
        let selector = try identity.keychainAccount()
        let outcomes: [(OSStatus, SafariApprovalKeyAvailability)] = [
            (errSecSuccess, .present),
            (errSecInteractionNotAllowed, .authenticationRequired),
            (errSecItemNotFound, .missing),
            (errSecMissingEntitlement, .unavailable(errSecMissingEntitlement)),
            (errSecAuthFailed, .unavailable(errSecAuthFailed)),
        ]
        for (status, expected) in outcomes {
            var queryCount = 0
            let store = SafariApprovalKeychainStore(
                add: { _, _ in
                    XCTFail("Availability must not add a key")
                    return errSecParam
                },
                copyMatching: { query, _ in
                    queryCount += 1
                    let query = query as NSDictionary
                    XCTAssertEqual(
                        query[kSecAttrAccount] as? String,
                        selector
                    )
                    XCTAssertEqual(
                        query[kSecAttrService] as? String,
                        SafariApprovalKeychainStore.service
                    )
                    XCTAssertEqual(
                        query[kSecAttrAccessGroup] as? String,
                        SafariApprovalKeychainStore.accessGroup
                    )
                    XCTAssertEqual(
                        query[kSecUseDataProtectionKeychain] as? Bool,
                        true
                    )
                    XCTAssertEqual(query[kSecReturnAttributes] as? Bool, true)
                    XCTAssertEqual(
                        query[kSecMatchLimit] as? String,
                        kSecMatchLimitOne as String
                    )
                    XCTAssertNil(query[kSecReturnData])
                    XCTAssertNil(query[kSecValueData])
                    let context = query[kSecUseAuthenticationContext] as? LAContext
                    XCTAssertEqual(context?.interactionNotAllowed, true)
                    return status
                },
                delete: { _ in
                    XCTFail("Availability must not delete a key")
                    return errSecParam
                }
            )

            XCTAssertEqual(store.availability(identities: [identity]), [identity: expected])
            XCTAssertEqual(queryCount, 1)
        }
    }

    func testAccountKeySelectorsBindTheExactDescriptorAndGeneration() throws {
        let generation = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let descriptor = WalletAccountDescriptor(
            walletID: "wallet", coin: .ethereum,
            normalizedAddress: "0x0000000000000000000000000000000000000042",
            derivationPath: "m/44'/60'/0'/0/0"
        )
        let identity = SafariApprovalKeyIdentity(generation: generation, account: descriptor)
        let selector = try identity.keychainAccount()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(descriptor))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(selector, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:" + digest)
        let decoded = try JSONDecoder().decode(
            WalletAccountDescriptor.self, from: JSONEncoder().encode(descriptor)
        )
        XCTAssertEqual(try SafariApprovalKeyIdentity(generation: generation, account: decoded).keychainAccount(), selector)

        let variants = [
            WalletAccountDescriptor(
                walletID: "other-wallet", coin: descriptor.coin,
                normalizedAddress: descriptor.normalizedAddress, derivationPath: descriptor.derivationPath
            ),
            WalletAccountDescriptor(
                walletID: descriptor.walletID, coin: .solana,
                normalizedAddress: descriptor.normalizedAddress, derivationPath: descriptor.derivationPath
            ),
            WalletAccountDescriptor(
                walletID: descriptor.walletID, coin: descriptor.coin,
                normalizedAddress: "0x0000000000000000000000000000000000000043",
                derivationPath: descriptor.derivationPath
            ),
            WalletAccountDescriptor(
                walletID: descriptor.walletID, coin: descriptor.coin,
                normalizedAddress: descriptor.normalizedAddress, derivationPath: "m/44'/60'/0'/0/1"
            )
        ]
        var selectors = Set([selector])
        for variant in variants {
            selectors.insert(try SafariApprovalKeyIdentity(generation: generation, account: variant).keychainAccount())
        }
        selectors.insert(try SafariApprovalKeyIdentity(generation: UUID(), account: descriptor).keychainAccount())
        XCTAssertEqual(selectors.count, variants.count + 2)
    }

    func testBulkKeyInventoryMatchesAccountSelectorsWithoutReadingSecrets() throws {
        let generation = UUID()
        let identities = try accountCountFixture(3).catalog.accounts.map {
            SafariApprovalKeyIdentity(generation: generation, account: $0)
        }
        let selectors = try identities.map { try $0.keychainAccount() }
        let foreignSelector = try SafariApprovalKeyIdentity(
            generation: UUID(), account: identities[1].account
        ).keychainAccount()
        var queries = 0
        let store = SafariApprovalKeychainStore(copyMatching: { query, result in
            queries += 1
            let query = query as NSDictionary
            XCTAssertNil(query[kSecAttrAccount])
            XCTAssertEqual(query[kSecMatchLimit] as? String, kSecMatchLimitAll as String)
            XCTAssertEqual(query[kSecClass] as? String, kSecClassGenericPassword as String)
            XCTAssertEqual(query[kSecAttrService] as? String, SafariApprovalKeychainStore.service)
            XCTAssertEqual(query[kSecAttrAccessGroup] as? String, SafariApprovalKeychainStore.accessGroup)
            XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, true)
            XCTAssertEqual(query[kSecReturnAttributes] as? Bool, true)
            XCTAssertNil(query[kSecReturnData])
            XCTAssertNil(query[kSecValueData])
            XCTAssertEqual((query[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed, true)
            result?.pointee = [selectors[2], foreignSelector, selectors[0]].map {
                [kSecAttrAccount as String: $0]
            } as CFArray
            return errSecSuccess
        })

        XCTAssertEqual(store.availability(identities: identities), [
            identities[0]: .present, identities[1]: .missing, identities[2]: .present
        ])
        XCTAssertEqual(queries, 1)
    }

    func testBulkAuthenticationRequiredFallsBackToExactMetadataQueries() throws {
        let generation = UUID()
        let identities = try accountCountFixture(4).catalog.accounts.map {
            SafariApprovalKeyIdentity(generation: generation, account: $0)
        }
        let selectors = try identities.map { try $0.keychainAccount() }
        let statuses = Dictionary(uniqueKeysWithValues: zip(selectors, [
            errSecSuccess, errSecInteractionNotAllowed, errSecItemNotFound, errSecAuthFailed
        ]))
        var queriedAccounts = [String]()
        var bulkQueries = 0
        var inventoryContext: LAContext?
        let store = SafariApprovalKeychainStore(copyMatching: { query, _ in
            let query = query as NSDictionary
            XCTAssertEqual(query[kSecReturnAttributes] as? Bool, true)
            XCTAssertNil(query[kSecReturnData])
            XCTAssertNil(query[kSecValueData])
            let context = query[kSecUseAuthenticationContext] as? LAContext
            XCTAssertEqual(context?.interactionNotAllowed, true)
            if query[kSecMatchLimit] as? String == kSecMatchLimitAll as String {
                bulkQueries += 1
                XCTAssertNil(query[kSecAttrAccount])
                inventoryContext = context
                return errSecInteractionNotAllowed
            }
            XCTAssertTrue(context === inventoryContext)
            XCTAssertEqual(query[kSecMatchLimit] as? String, kSecMatchLimitOne as String)
            guard let account = query[kSecAttrAccount] as? String,
                  let status = statuses[account] else {
                XCTFail("Fallback must query only the requested account identities")
                return errSecParam
            }
            queriedAccounts.append(account)
            return status
        })

        XCTAssertEqual(store.availability(identities: identities), [
            identities[0]: .present,
            identities[1]: .authenticationRequired,
            identities[2]: .missing,
            identities[3]: .unavailable(errSecAuthFailed)
        ])
        XCTAssertEqual(bulkQueries, 1)
        XCTAssertEqual(queriedAccounts, selectors)
    }

    func testMalformedBulkKeyMetadataFailsClosed() throws {
        let generation = UUID()
        let identities = try accountCountFixture(2).catalog.accounts.map {
            SafariApprovalKeyIdentity(generation: generation, account: $0)
        }
        let selector = try identities[0].keychainAccount()
        let malformedResults: [CFTypeRef?] = [
            nil,
            Data([0x01]) as CFData,
            [kSecAttrAccount as String: selector] as CFDictionary,
            [["unexpected": selector]] as CFArray,
            [[kSecAttrAccount as String: 1]] as CFArray,
            [[kSecAttrAccount as String: selector], [:]] as CFArray
        ]
        for attributes in malformedResults {
            var queries = 0
            let store = SafariApprovalKeychainStore(copyMatching: { query, result in
                queries += 1
                let query = query as NSDictionary
                XCTAssertEqual(query[kSecMatchLimit] as? String, kSecMatchLimitAll as String)
                XCTAssertNil(query[kSecReturnData])
                result?.pointee = attributes
                return errSecSuccess
            })
            XCTAssertEqual(store.availability(identities: identities), [
                identities[0]: .unavailable(errSecDecode), identities[1]: .unavailable(errSecDecode)
            ])
            XCTAssertEqual(queries, 1)
        }
    }

    func testEmptyKeyInventoryDoesNotQueryKeychain() {
        let store = SafariApprovalKeychainStore(copyMatching: { _, _ in
            XCTFail("An empty account catalog needs no Keychain query")
            return errSecParam
        })
        XCTAssertTrue(store.availability(identities: []).isEmpty)
    }

    func testAccountKeyPublicationAndCatalogReadCostsWithMockedKeychain() throws {
        for accountCount in [1, 100] {
            let source = try accountCountFixture(accountCount)
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let keychain = ProtectedApprovalKeychainFixture()
            keychain.availabilityStatus = errSecSuccess
            let vault = SafariApprovalVault(fileURL: url, keyStore: keychain.store)
            let start = ContinuousClock.now
            try vault.publish(source: source, integrityKey: integrityKey)
            let publicationDuration = start.duration(to: .now)
            XCTAssertEqual(keychain.events.filter { $0 == "add" }.count, accountCount)
            XCTAssertEqual(keychain.keys.count, accountCount)
            XCTAssertEqual(keychain.availabilityReads, 1)

            var catalogDurations = [Duration]()
            for _ in 0..<5 {
                let readsBefore = keychain.availabilityReads
                let start = ContinuousClock.now
                let catalog = try XCTUnwrap(vault.reviewCatalog())
                catalogDurations.append(start.duration(to: .now))
                XCTAssertEqual(catalog.orderedAccounts.count, accountCount)
                XCTAssertEqual(keychain.availabilityReads - readsBefore, 1)
            }
            XCTAssertEqual(keychain.protectedKeyReads, 0)
            print("Safari approval mocked Keychain: accounts=\(accountCount), publication=\(publicationDuration), catalog reads=\(catalogDurations)")
        }
    }

    func testKeyDeletionIsScopedAndDoesNotEnumerateProtectedItems() throws {
        for status in [errSecSuccess, errSecItemNotFound, errSecIO] {
            var deletionCount = 0
            let store = SafariApprovalKeychainStore(
                copyMatching: { _, _ in
                    XCTFail("Deletion must not read protected items")
                    return errSecInteractionNotAllowed
                },
                delete: { query in
                    deletionCount += 1
                    let query = query as NSDictionary
                    XCTAssertEqual(
                        query[kSecClass] as? String,
                        kSecClassGenericPassword as String
                    )
                    XCTAssertEqual(
                        query[kSecAttrAccessGroup] as? String,
                        SafariApprovalKeychainStore.accessGroup
                    )
                    XCTAssertEqual(
                        query[kSecAttrService] as? String,
                        SafariApprovalKeychainStore.service
                    )
                    XCTAssertEqual(
                        query[kSecUseDataProtectionKeychain] as? Bool,
                        true
                    )
                    XCTAssertNil(query[kSecAttrAccount])
                    XCTAssertNil(query[kSecReturnAttributes])
                    XCTAssertNil(query[kSecReturnData])
                    return status
                }
            )
            if status == errSecIO {
                XCTAssertThrowsError(try store.removeAll()) { error in
                    XCTAssertEqual(
                        error as? SafariApprovalVault.Error,
                        .keychainFailure(errSecIO)
                    )
                }
            } else {
                XCTAssertNoThrow(try store.removeAll())
            }
            XCTAssertEqual(deletionCount, 1)
        }
    }

    func testProtectedKeychainPublicationSurvivesRepeatedForegroundReconciliation()
        async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = ProtectedApprovalKeychainFixture()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keychain.store,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )

        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}

        let first = try XCTUnwrap(vault.reviewCatalog())
        let envelope = try Data(contentsOf: url)
        let metadata = try XCTUnwrap(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ))
        let events = keychain.events
        XCTAssertEqual(keychain.keys.count, 1)
        XCTAssertEqual(events.filter { $0 == "add" }.count, 1)

        for _ in 0..<3 {
            host.reconcile()
            reconciliationQueue.sync {}
            XCTAssertEqual(vault.reviewCatalog()?.identity, first.identity)
        }

        XCTAssertEqual(try Data(contentsOf: url), envelope)
        XCTAssertEqual(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ), metadata)
        XCTAssertEqual(keychain.events, events)
        XCTAssertEqual(keychain.protectedKeyReads, 0)
        XCTAssertGreaterThan(keychain.availabilityReads, 0)

        let unlockedValue = await vault.unlockSignerForTesting(reason: "Approve")
        let unlocked = try XCTUnwrap(unlockedValue)
        try await assertSigningAccessForTesting(unlocked, walletID: "wallet", account: try fixture().account, expectedSuccess: true)
        let leaseValue = await unlocked.takeCommitLease()
        let lease = try XCTUnwrap(leaseValue)
        lease.release()
        XCTAssertEqual(keychain.protectedKeyReads, 1)
    }

    func testHostPreservesKnownPublicationDuringUnexpectedAvailabilityFailure()
        throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = ProtectedApprovalKeychainFixture()
        let vault = SafariApprovalVault(fileURL: url, keyStore: keychain.store)
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let first = try XCTUnwrap(vault.reviewCatalog()?.identity)
        let envelope = try Data(contentsOf: url)
        let metadata = try XCTUnwrap(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ))
        let events = keychain.events
        keychain.availabilityStatus = errSecMissingEntitlement

        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertNil(vault.reviewCatalog())
        XCTAssertEqual(try Data(contentsOf: url), envelope)
        XCTAssertEqual(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ), metadata)
        XCTAssertEqual(keychain.events, events)
        XCTAssertEqual(keychain.keys.count, 1)

        keychain.availabilityStatus = errSecInteractionNotAllowed
        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertEqual(vault.reviewCatalog()?.identity, first)
        XCTAssertEqual(keychain.events, events)
    }

    func testHostRepairsPublicationWhenOneAccountKeyIsMissing() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = ProtectedApprovalKeychainFixture()
        let vault = SafariApprovalVault(fileURL: url, keyStore: keychain.store)
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try accountCountFixture(3)
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let first = try XCTUnwrap(vault.reviewCatalog()?.identity)
        let missingIdentity = SafariApprovalKeyIdentity(
            generation: try XCTUnwrap(first.generation), account: source.catalog.accounts[1]
        )
        keychain.keys.removeValue(forKey: try missingIdentity.keychainAccount())
        XCTAssertEqual(vault.reviewCatalog()?.orderedAccounts.count, 2)

        host.reconcile()
        reconciliationQueue.sync {}

        let repaired = try XCTUnwrap(vault.reviewCatalog()?.identity)
        XCTAssertNotEqual(repaired.generation, first.generation)
        XCTAssertEqual(repaired.catalogData, first.catalogData)
        XCTAssertEqual(keychain.keys.count, 3)
        XCTAssertEqual(keychain.events.filter { $0 == "add" }.count, 6)
        XCTAssertEqual(keychain.protectedKeyReads, 0)
    }

    func testUnknownAccountKeyAvailabilityPreservesPublicationBeforeMissingKeyRepair() throws {
        let source = try accountCountFixture(3)
        for missingIndex in [0, 1] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let keys = MemoryApprovalKeyStore()
            let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
            let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let queue = DispatchQueue(label: "SafariApprovalVaultHostTests.partialAvailability")
            let host = SafariApprovalVaultHost(
                vault: vault, defaults: defaults,
                integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
                reconciliationQueue: queue, sourceSnapshot: { source }
            )
            host.start(backgroundTask: { _ in {} })
            queue.sync {}
            let original = try XCTUnwrap(vault.reviewCatalog())
            let generation = try XCTUnwrap(original.identity.generation)
            let identities = source.catalog.accounts.map { SafariApprovalKeyIdentity(generation: generation, account: $0) }
            let envelope = try Data(contentsOf: url)
            let metadata = defaults.data(forKey: "SafariApprovalVault.hostPublicationMetadata.v1")
            keys.keys.removeValue(forKey: identities[missingIndex])
            keys.availabilityOverrides[identities[1 - missingIndex]] = .unavailable(errSecIO)
            let remainingKeys = keys.keys

            host.reconcile()
            queue.sync {}

            XCTAssertEqual(try Data(contentsOf: url), envelope)
            XCTAssertEqual(defaults.data(forKey: "SafariApprovalVault.hostPublicationMetadata.v1"), metadata)
            XCTAssertEqual(keys.keys, remainingKeys)
            XCTAssertEqual(vault.reviewCatalog()?.identity, original.identity)
            XCTAssertEqual(vault.reviewCatalog()?.orderedAccounts, [source.catalog.accounts[2].specificAccount])
            XCTAssertTrue(keys.loadedIdentities.isEmpty)

            keys.availabilityOverrides.removeAll()
            host.reconcile()
            queue.sync {}

            XCTAssertNotEqual(vault.reviewCatalog()?.identity.generation, generation)
            XCTAssertEqual(vault.reviewCatalog()?.orderedAccounts, original.orderedAccounts)
            XCTAssertEqual(keys.keys.count, 3)
        }
    }

    func testCompleteKeySetIsInstalledBeforeEnvelopePublication() throws {
        let source = try accountCountFixture(3)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var events = [String]()
        keys.onRemove = { events.append("delete") }
        keys.onStore = { _ in
            events.append("store")
            XCTAssertEqual(try? Data(contentsOf: url), Data())
        }
        let vault = SafariApprovalVault(
            fileURL: url, keyStore: keys,
            atomicWrite: { data, destination in
                events.append(data.isEmpty ? "tombstone" : "envelope")
                if !data.isEmpty {
                    XCTAssertEqual(keys.keys.count, 3)
                    XCTAssertEqual(keys.availabilityRequests.last?.count, 3)
                }
                try data.write(to: destination, options: .atomic)
            }
        )
        try vault.publish(source: source, integrityKey: integrityKey)
        XCTAssertEqual(events, ["tombstone", "delete", "store", "store", "store", "envelope"])
        XCTAssertEqual(vault.reviewCatalog()?.orderedAccounts.count, 3)
        XCTAssertTrue(keys.loadedIdentities.isEmpty)
    }

    func testPartialKeyInsertionCleansUpIndependentlyAndCanRecover() throws {
        let source = try accountCountFixture(3)
        for cleanupFailure in ["none", "tombstone", "keys"] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let keys = MemoryApprovalKeyStore()
            var writes = 0
            var insertions = 0
            var deletions = 0
            var events = [String]()
            keys.onStore = { _ in
                insertions += 1
                events.append("store")
                if insertions == 2 { keys.storeError = SafariApprovalVault.Error.keychainFailure(errSecIO) }
            }
            keys.onRemove = {
                deletions += 1
                events.append("delete")
                if deletions == 2 && cleanupFailure == "keys" {
                    keys.removeError = SafariApprovalVault.Error.keychainFailure(errSecIO)
                }
            }
            let vault = SafariApprovalVault(
                fileURL: url, keyStore: keys,
                atomicWrite: { data, destination in
                    writes += 1
                    events.append(data.isEmpty ? "tombstone" : "envelope")
                    if writes == 2 && cleanupFailure == "tombstone" { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: destination, options: .atomic)
                }
            )
            XCTAssertThrowsError(try vault.publish(source: source, integrityKey: integrityKey))
            XCTAssertEqual(events, ["tombstone", "delete", "store", "store", "tombstone", "delete"])
            XCTAssertEqual(try Data(contentsOf: url), Data())
            XCTAssertNil(vault.reviewCatalog())
            XCTAssertEqual(keys.keys.count, cleanupFailure == "keys" ? 1 : 0)

            keys.storeError = nil
            keys.removeError = nil
            keys.onStore = nil
            keys.onRemove = nil
            let publication = try vault.publish(source: source, integrityKey: integrityKey)
            XCTAssertEqual(keys.keys.count, 3)
            XCTAssertTrue(keys.keys.keys.allSatisfy { $0.generation == publication.generation })
            XCTAssertEqual(vault.reviewCatalog()?.orderedAccounts.count, 3)
        }
    }

    func testHostRecoversTombstoneWithOrphanedAccountKeys() throws {
        let source = try accountCountFixture(3)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        let keys = MemoryApprovalKeyStore()
        let abandonedGeneration = UUID()
        let abandoned = SafariApprovalKeyIdentity(generation: abandonedGeneration, account: source.catalog.accounts[0])
        keys.keys[abandoned] = Data(repeating: 4, count: 32)
        let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
        XCTAssertNil(vault.reviewCatalog())
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = DispatchQueue(label: "SafariApprovalVaultHostTests.crashRecovery")
        let host = SafariApprovalVaultHost(
            vault: vault, defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            reconciliationQueue: queue, sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        queue.sync {}
        let recovered = try XCTUnwrap(vault.reviewCatalog())
        XCTAssertNotEqual(recovered.identity.generation, abandonedGeneration)
        XCTAssertEqual(recovered.orderedAccounts.count, 3)
        XCTAssertNil(keys.keys[abandoned])
        XCTAssertEqual(keys.keys.count, 3)
        XCTAssertTrue(keys.loadedIdentities.isEmpty)
    }

    func testChangedSourceCannotKeepPublicationWhenKeyAvailabilityIsUnknown()
        throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = ProtectedApprovalKeychainFixture()
        let vault = SafariApprovalVault(fileURL: url, keyStore: keychain.store)
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let oldGeneration = try XCTUnwrap(vault.reviewCatalog()?.identity.generation)
        try reformatStoredKey(in: &source)
        keychain.availabilityStatus = errSecMissingEntitlement

        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertNil(vault.reviewCatalog())
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertFalse(keychain.keys.keys.contains { $0.hasPrefix(oldGeneration.uuidString.lowercased() + ":") })
        XCTAssertNil(defaults.data(forKey: "SafariApprovalVault.hostPublicationMetadata.v1"))

        keychain.availabilityStatus = errSecInteractionNotAllowed
        host.reconcile()
        reconciliationQueue.sync {}

        let repaired = try XCTUnwrap(vault.reviewCatalog()?.identity)
        XCTAssertNotEqual(repaired.generation, oldGeneration)
    }

    func testPublicationDeletesProtectedKeysBeforeAddingAndStopsOnDeleteFailure()
        throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = ProtectedApprovalKeychainFixture()
        keychain.keys[UUID().uuidString.lowercased()] = Data(repeating: 1, count: 32)
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keychain.store,
            atomicWrite: { data, destination in
                keychain.events.append(data.isEmpty ? "tombstone" : "envelope")
                try data.write(to: destination, options: .atomic)
            }
        )
        let source = try fixture().source

        try vault.publish(source: source, integrityKey: integrityKey)

        XCTAssertEqual(keychain.events, ["tombstone", "delete", "add", "envelope"])
        XCTAssertEqual(keychain.keys.count, 1)
        XCTAssertNotNil(vault.reviewCatalog())
        keychain.events.removeAll()
        keychain.deleteStatus = errSecIO

        XCTAssertThrowsError(try vault.publish(
            source: source,
            integrityKey: integrityKey
        )) { error in
            XCTAssertEqual(error as? SafariApprovalVault.Error, .keychainFailure(errSecIO))
        }

        XCTAssertEqual(keychain.events, ["tombstone", "delete", "tombstone", "delete"])
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertNil(vault.reviewCatalog())
        XCTAssertEqual(keychain.keys.count, 1)
        XCTAssertEqual(keychain.protectedKeyReads, 0)
    }

    func testProtectedAvailabilityDoesNotBypassCancellationOrFailedKeyRetrieval()
        async throws {
        for authenticated in [false, true] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let keychain = ProtectedApprovalKeychainFixture()
            keychain.loadStatus = errSecAuthFailed
            var authenticationAttempts = 0
            let vault = SafariApprovalVault(
                fileURL: url,
                keyStore: keychain.store,
                canEvaluateAuthentication: { _, _ in true },
                authentication: { _, _, _ in
                    authenticationAttempts += 1
                    return authenticated
                }
            )
            let fixture = try fixture()
            try vault.publish(
                source: fixture.source,
                integrityKey: integrityKey
            )
            let catalog = try XCTUnwrap(vault.reviewCatalog())

            let result = await vault.unlockResult(
                reason: "Approve",
                authorization: walletSigningAuthorizationForTesting(approvedAccount: WalletAccountDescriptor(walletID: "wallet", account: fixture.account))
            )

            switch result {
            case .canceled:
                XCTAssertFalse(authenticated)
            case .unavailable:
                XCTAssertTrue(authenticated)
            case .unlocked:
                XCTFail("Protected availability must never authorize key access")
            }
            XCTAssertEqual(authenticationAttempts, 1)
            XCTAssertEqual(keychain.protectedKeyReads, authenticated ? 1 : 0)
        }
    }

    @MainActor
    func testReconciliationAssertionCoversLeaseAndSourceAndUsesFirstFactory() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = SafariApprovalVault(fileURL: url, keyStore: MemoryApprovalKeyStore())
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        var events = [String]()
        var replacementBegins = 0
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: {
                events.append("source")
                XCTAssertEqual(events.last(where: { $0 != "source" }), "begin")
                XCTAssertNil(try vault.tryAcquireCoordinationLease())
                return source
            }
        )
        host.start(backgroundTask: { _ in
            events.append("begin")
            let lease = try? vault.tryAcquireCoordinationLease()
            XCTAssertNotNil(lease)
            lease?.release()
            return {
                events.append("end")
                let lease = try? vault.tryAcquireCoordinationLease()
                XCTAssertNotNil(lease)
                lease?.release()
            }
        })
        reconciliationQueue.sync {}
        let original = try XCTUnwrap(vault.reviewCatalog()?.identity)
        XCTAssertEqual(events, ["begin", "source", "end"])
        host.start(backgroundTask: { _ in
            replacementBegins += 1
            return {}
        })
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertEqual(events, ["begin", "source", "end", "begin", "source", "end"])
        XCTAssertEqual(replacementBegins, 0)
        XCTAssertEqual(vault.reviewCatalog()?.identity, original)
    }

    func testDeniedOrImmediatelyExpiredAssertionSkipsWorkAndForegroundRetryRecovers()
        throws {
        for expireImmediately in [false, true] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let keys = MemoryApprovalKeyStore()
            var writes = 0
            let vault = SafariApprovalVault(
                fileURL: url,
                keyStore: keys,
                atomicWrite: { data, destination in
                    writes += 1
                    try data.write(to: destination, options: .atomic)
                }
            )
            let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let source = try fixture().source
            var sourceReads = 0
            var begins = 0
            var ends = 0
            var shouldSucceed = false
            let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
            let host = SafariApprovalVaultHost(
                vault: vault,
                defaults: defaults,
                integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
                reconciliationQueue: reconciliationQueue,
                sourceSnapshot: {
                    sourceReads += 1
                    return source
                }
            )
            host.start(backgroundTask: { expire in
                begins += 1
                if !shouldSucceed {
                    guard expireImmediately else { return nil }
                    expire()
                }
                return { ends += 1 }
            })
            reconciliationQueue.sync {}
            XCTAssertEqual(begins, 1)
            XCTAssertEqual(ends, expireImmediately ? 1 : 0)
            XCTAssertEqual(sourceReads, 0)
            XCTAssertEqual(writes, 0)
            XCTAssertTrue(keys.keys.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath:
                url.appendingPathExtension("coordination-lock").path))
            XCTAssertNil(defaults.data(forKey: "SafariApprovalVault.hostPublicationMetadata.v1"))

            shouldSucceed = true
            host.reconcile()
            reconciliationQueue.sync {}
            XCTAssertEqual(begins, 2)
            XCTAssertEqual(ends, expireImmediately ? 2 : 1)
            XCTAssertEqual(sourceReads, 1)
            XCTAssertNotNil(vault.reviewCatalog())
        }
    }

    @MainActor
    func testExpirationReleasesLeaseBeforeBlockedSourceReturnsAndPreservesNewerPublication()
        async throws {
        for sourceFails in [false, true] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let keys = MemoryApprovalKeyStore()
            let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
            let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let source = try fixture().source
            let replacement = try mnemonicFixture().source
            let workerStarted = expectation(description: "Source read holds coordination lease")
            let releaseSource = DispatchSemaphore(value: 0)
            defer { releaseSource.signal() }
            var expire: (() -> Void)?
            var ends = 0
            var sourceReads = 0
            let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
            let host = SafariApprovalVaultHost(
                vault: vault,
                defaults: defaults,
                integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
                reconciliationQueue: reconciliationQueue,
                sourceSnapshot: {
                    sourceReads += 1
                    if sourceReads == 1 {
                        workerStarted.fulfill()
                        XCTAssertEqual(releaseSource.wait(timeout: .now() + 5), .success)
                        if sourceFails { throw CocoaError(.fileReadUnknown) }
                        return source
                    }
                    return replacement
                }
            )
            host.start(backgroundTask: { expiration in
                expire = expiration
                return { ends += 1 }
            })
            await fulfillment(of: [workerStarted], timeout: 2)
            XCTAssertNil(try vault.tryAcquireCoordinationLease())
            let expireActivity = try XCTUnwrap(expire)
            let startedAt = ContinuousClock.now
            expireActivity()
            XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
            XCTAssertEqual(ends, 1)
            expireActivity()
            XCTAssertEqual(ends, 1)
            let replacementLease = try XCTUnwrap(vault.tryAcquireCoordinationLease())
            let publication = try vault.publish(
                source: replacement,
                integrityKey: integrityKey,
                coordinationLease: replacementLease
            )
            replacementLease.release()
            let newerEnvelope = try Data(contentsOf: url)
            let newerMetadata = Data("newer-host-publication".utf8)
            defaults.set(newerMetadata, forKey: "SafariApprovalVault.hostPublicationMetadata.v1")
            releaseSource.signal()
            reconciliationQueue.sync {}
            XCTAssertEqual(ends, 1)
            XCTAssertEqual(try Data(contentsOf: url), newerEnvelope)
            XCTAssertEqual(vault.reviewCatalog()?.identity.generation, publication.generation)
            XCTAssertEqual(defaults.data(forKey: "SafariApprovalVault.hostPublicationMetadata.v1"), newerMetadata)

            host.reconcile()
            reconciliationQueue.sync {}
            XCTAssertEqual(sourceReads, 2)
            XCTAssertEqual(ends, 2)
            XCTAssertEqual(vault.reviewCatalog()?.identity.catalogData,
                           try (replacement.catalog).canonicalData())
        }
    }

    func testExpiredPublicationSkipsPersistentEffectsAfterKeyGeneration() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var events = [String]()
        keys.onStore = { _ in events.append("store") }
        keys.onRemove = { events.append("remove") }
        var expire: (() -> Void)?
        var ends = 0
        let activity = try XCTUnwrap(SafariApprovalReconciliationActivity(begin: { expiration in
            expire = expiration
            return { ends += 1 }
        }))
        defer { activity.finish() }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            randomKey: {
                events.append("random-key")
                expire?()
                return Data(repeating: 7, count: 32)
            },
            atomicWrite: { data, destination in
                events.append("write")
                try data.write(to: destination, options: .atomic)
            }
        )
        let lease = try XCTUnwrap(activity.acquireLease(from: vault))
        XCTAssertThrowsError(try vault.publish(
            source: fixture().source,
            integrityKey: integrityKey,
            coordinationLease: lease,
            activity: activity
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(events, ["random-key"])
        XCTAssertEqual(ends, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let nextLease = try XCTUnwrap(vault.tryAcquireCoordinationLease())
        nextLease.release()
        XCTAssertThrowsError(try activity.checkCancellation())
        activity.finish()
        XCTAssertEqual(ends, 1)
    }

    func testExpirationDuringFirstAccountKeyStoreStopsPublication() throws {
        let source = try accountCountFixture(3)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var expire: (() -> Void)?
        var ends = 0
        let activity = try XCTUnwrap(SafariApprovalReconciliationActivity(begin: {
            expire = $0
            return { ends += 1 }
        }))
        defer { activity.finish() }
        var stores = 0
        var deletions = 0
        keys.onStore = { _ in stores += 1; expire?() }
        keys.onRemove = { deletions += 1 }
        let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
        let lease = try XCTUnwrap(activity.acquireLease(from: vault))

        XCTAssertThrowsError(try vault.publish(
            source: source, integrityKey: integrityKey, coordinationLease: lease, activity: activity
        )) { XCTAssertTrue($0 is CancellationError) }

        XCTAssertEqual(stores, 1)
        XCTAssertEqual(deletions, 1)
        XCTAssertEqual(ends, 1)
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertNil(vault.reviewCatalog())
        XCTAssertEqual(keys.keys.count, 1)
        keys.onStore = nil
        let recovered = try vault.publish(source: source, integrityKey: integrityKey)
        XCTAssertEqual(keys.keys.count, 3)
        XCTAssertTrue(keys.keys.keys.allSatisfy { $0.generation == recovered.generation })
        XCTAssertEqual(vault.reviewCatalog()?.orderedAccounts.count, 3)
    }

    @MainActor
    func testExpirationDuringKeyInventoryReturnsPromptlyAndPreservesNewerPublication() async throws {
        let source = try accountCountFixture(3)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let inventoryStarted = expectation(description: "Publication is checking key metadata")
        let publicationFinished = expectation(description: "Expired publication stops")
        let releaseInventory = DispatchSemaphore(value: 0)
        defer { releaseInventory.signal() }
        var blockInventory = true
        keys.onAvailability = {
            guard blockInventory else { return }
            blockInventory = false
            inventoryStarted.fulfill()
            XCTAssertEqual(releaseInventory.wait(timeout: .now() + 5), .success)
        }
        var expire: (() -> Void)?
        let activity = try XCTUnwrap(SafariApprovalReconciliationActivity(begin: {
            expire = $0
            return {}
        }))
        defer { activity.finish() }
        let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
        let lease = try XCTUnwrap(activity.acquireLease(from: vault))
        let integrityKey = integrityKey
        DispatchQueue.global().async {
            do {
                try vault.publish(
                    source: source, integrityKey: integrityKey, coordinationLease: lease, activity: activity
                )
                XCTFail("Expired publication must stop")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            publicationFinished.fulfill()
        }
        await fulfillment(of: [inventoryStarted], timeout: 2)
        let expireActivity = try XCTUnwrap(expire)
        let expirationReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            expireActivity()
            expirationReturned.signal()
        }
        let expirationResult = expirationReturned.wait(timeout: .now() + 1)
        XCTAssertEqual(expirationResult, .success)
        guard expirationResult == .success else {
            releaseInventory.signal()
            await fulfillment(of: [publicationFinished], timeout: 5)
            return
        }

        let replacementVault = SafariApprovalVault(fileURL: url, keyStore: keys)
        let replacement = try replacementVault.publish(source: source, integrityKey: integrityKey)
        let replacementData = try Data(contentsOf: url)
        let replacementKeys = keys.keys
        releaseInventory.signal()
        await fulfillment(of: [publicationFinished], timeout: 2)

        XCTAssertEqual(try Data(contentsOf: url), replacementData)
        XCTAssertEqual(keys.keys, replacementKeys)
        XCTAssertEqual(vault.reviewCatalog()?.identity.generation, replacement.generation)
    }

    func testOwnershipValidationStopsOnCancellationBeforeDecryptionAndAccountDerivation()
        throws {
        let source = try orderedFixture().source
        let wallets = try XCTUnwrap(WalletSnapshotValidation.wallets(
            catalog: source.catalog,
            walletRecords: source.wallets.map {
                (id: $0.walletID, data: $0.storedKeyJSON)
            }
        ))
        for wallet in wallets {
            for cancelAt in [1, 2, 3] {
                var checks = 0
                var expire: (() -> Void)?
                let activity = try XCTUnwrap(SafariApprovalReconciliationActivity(begin: {
                    expire = $0
                    return {}
                }))
                defer { activity.finish() }
                XCTAssertThrowsError(try WalletSnapshotValidation.visitOwnedAccountKeys(
                    wallet,
                    password: source.password,
                    checkCancellation: {
                        checks += 1
                        if checks == cancelAt { expire?() }
                        try activity.checkCancellation()
                    },
                    visit: { _, _ in }
                )) { XCTAssertTrue($0 is CancellationError) }
                XCTAssertEqual(checks, cancelAt)
            }
        }

        var checks = 0
        var visitedWallets = 0
        XCTAssertThrowsError(try wallets.allSatisfy { wallet in
            visitedWallets += 1
            return try WalletSnapshotValidation.visitOwnedAccountKeys(
                wallet,
                password: source.password,
                checkCancellation: {
                    checks += 1
                    if checks == 4 { throw CancellationError() }
                },
                visit: { _, _ in }
            )
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 4)
        XCTAssertEqual(visitedWallets, 1)
    }

    @MainActor
    func testLifecycleRequestsReturnWhileWorkerIsBlockedAndCoalesceFollowUp()
        async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var stores = 0
        keys.onStore = { _ in stores += 1 }
        let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        let workerStarted = expectation(description: "Background validation started")
        let followUpStarted = expectation(description: "One follow-up started")
        let mainActorResponsive = expectation(description: "Main actor remains responsive")
        let releaseWorker = DispatchSemaphore(value: 0)
        defer { releaseWorker.signal() }
        var sourceReads = 0
        var firstIdentity: WalletCatalogIdentity?
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: {
                XCTAssertFalse(Thread.isMainThread)
                sourceReads += 1
                if sourceReads == 1 {
                    workerStarted.fulfill()
                    XCTAssertEqual(releaseWorker.wait(timeout: .now() + 5), .success)
                } else if sourceReads == 2 {
                    firstIdentity = vault.reviewCatalog()?.identity
                    followUpStarted.fulfill()
                }
                return source
            }
        )
        reconciliationQueue.suspend()
        let initialStartedAt = ContinuousClock.now
        for _ in 0..<10 {
            host.start(backgroundTask: { _ in {} })
            host.reconcile()
        }
        XCTAssertLessThan(initialStartedAt.duration(to: .now), .seconds(1))
        XCTAssertEqual(sourceReads, 0)
        reconciliationQueue.resume()
        await fulfillment(of: [workerStarted], timeout: 2)

        let followUpStartedAt = ContinuousClock.now
        for _ in 0..<10 {
            host.start(backgroundTask: { _ in {} })
            host.reconcile()
        }
        XCTAssertLessThan(followUpStartedAt.duration(to: .now), .seconds(1))
        Task { @MainActor in mainActorResponsive.fulfill() }
        await fulfillment(of: [mainActorResponsive], timeout: 1)
        releaseWorker.signal()
        await fulfillment(of: [followUpStarted], timeout: 5)
        reconciliationQueue.sync {}

        XCTAssertEqual(sourceReads, 2)
        XCTAssertEqual(stores, 1)
        XCTAssertEqual(vault.reviewCatalog()?.identity, try XCTUnwrap(firstIdentity))
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        XCTAssertEqual(sourceReads, 2)
    }

    @MainActor
    func testSourceMutationWaitsForPublicationWithoutBlockingMainActor() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = SafariApprovalVault(fileURL: url, keyStore: MemoryApprovalKeyStore())
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        let workerStarted = expectation(description: "Publication started")
        let mutationStarted = expectation(description: "Mutation waiting")
        let releaseWorker = DispatchSemaphore(value: 0)
        defer { releaseWorker.signal() }
        var sourceReads = 0
        var mutations = 0
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: {
                sourceReads += 1
                if sourceReads == 1 {
                    workerStarted.fulfill()
                    XCTAssertEqual(releaseWorker.wait(timeout: .now() + 8), .success)
                }
                return source
            }
        )
        host.start(backgroundTask: { _ in {} })
        await fulfillment(of: [workerStarted], timeout: 2)

        let startedAt = ContinuousClock.now
        let mutation = Task {
            mutationStarted.fulfill()
            return try await host.performSourceMutation(preparing: {}) { _ in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertNil(vault.reviewCatalog())
                mutations += 1
                return "saved"
            }
        }
        await fulfillment(of: [mutationStarted], timeout: 1)
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
        XCTAssertEqual(mutations, 0)
        try await Task.sleep(nanoseconds: SafariApprovalVault.coordinationLockTimeoutNanoseconds + 100_000_000)
        XCTAssertEqual(mutations, 0)
        releaseWorker.signal()

        let result = try await mutation.value
        XCTAssertEqual(result, "saved")
        XCTAssertEqual(mutations, 1)
        reconciliationQueue.sync {}
        XCTAssertNotNil(vault.reviewCatalog())
    }

    @MainActor
    func testCanceledSourceMutationDoesNotWriteAfterExecutionLeaseIsReleased() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = SafariApprovalVault(fileURL: url, keyStore: MemoryApprovalKeyStore())
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = SafariApprovalVaultHost(vault: vault, defaults: defaults)
        let lease = try vault.acquireCoordinationLease()
        defer { lease.release() }
        let waiting = expectation(description: "Mutation waiting for execution lease")
        let mutation = Task {
            waiting.fulfill()
            try await host.performSourceMutation(preparing: {}) { _ in
                XCTFail("Canceled mutation must not execute")
            }
        }
        await fulfillment(of: [waiting], timeout: 1)
        mutation.cancel()
        lease.release()
        do {
            try await mutation.value
            XCTFail("Mutation must be canceled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testSourceMutationStillTimesOutOnExecutionLease() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = SafariApprovalVault(fileURL: url, keyStore: MemoryApprovalKeyStore())
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { nil }
        )
        let lease = try vault.acquireCoordinationLease()
        defer { lease.release() }
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let startedAt = ContinuousClock.now
        do {
            try await host.performSourceMutation(preparing: {
                XCTFail("Preparation must wait for the execution lease")
            }) { _ in
                XCTFail("Mutation must not execute without the lease")
            }
            XCTFail("Mutation must time out")
        } catch {
            XCTAssertEqual(error as? SafariApprovalVault.Error, .unavailable)
        }
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(7))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testRejectedPreparationPreservesPublishedVault() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let original = try XCTUnwrap(vault.reviewCatalog()?.identity)
        let envelope = try Data(contentsOf: url)
        do {
            try await host.performSourceMutation(preparing: { () throws -> Void in
                XCTAssertEqual(vault.reviewCatalog()?.identity, original)
                throw WalletKeyStoreError.invalidPassword
            }) { _ in
                XCTFail("Rejected preparation must not execute")
            }
            XCTFail("Preparation must fail")
        } catch {
            guard case WalletKeyStoreError.invalidPassword = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        reconciliationQueue.sync {}
        XCTAssertEqual(vault.reviewCatalog()?.identity, original)
        XCTAssertEqual(try Data(contentsOf: url), envelope)
        XCTAssertTrue(keys.keys.keys.contains { $0.generation == original.generation })
    }

    @MainActor
    func testScopedSourceMutationPreparationFailurePreservesPublishedVault() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault, defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            reconciliationQueue: reconciliationQueue, sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let original = try XCTUnwrap(vault.reviewCatalog()?.identity)
        let envelope = try Data(contentsOf: url)
        do {
            try await host.performSourceMutation { _ -> Void in
                XCTAssertEqual(vault.reviewCatalog()?.identity, original)
                throw WalletKeyStoreError.invalidPassword
            }
            XCTFail("Preparation must fail")
        } catch {
            guard case WalletKeyStoreError.invalidPassword = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        reconciliationQueue.sync {}
        XCTAssertEqual(vault.reviewCatalog()?.identity, original)
        XCTAssertEqual(try Data(contentsOf: url), envelope)
        XCTAssertTrue(keys.keys.keys.contains { $0.generation == original.generation })
    }

    @MainActor
    func testScopedSourceMutationInvalidatesOnceBeforeWritingAndReconciles() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault, defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            reconciliationQueue: reconciliationQueue, sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let original = try XCTUnwrap(vault.reviewCatalog()?.identity)
        var invalidations = 0
        keys.onRemove = { invalidations += 1 }
        let result = try await host.performSourceMutation { willMutateSource in
            XCTAssertEqual(vault.reviewCatalog()?.identity, original)
            try willMutateSource()
            XCTAssertNil(vault.reviewCatalog())
            XCTAssertEqual(invalidations, 1)
            try willMutateSource()
            XCTAssertEqual(invalidations, 1)
            return 42
        }
        XCTAssertEqual(result, 42)
        reconciliationQueue.sync {}
        let recovered = try XCTUnwrap(vault.reviewCatalog()?.identity)
        XCTAssertNotEqual(recovered.generation, original.generation)
        XCTAssertEqual(recovered.catalogData, original.catalogData)
    }

    @MainActor
    func testScopedSourceMutationFailuresReconcileAfterInvalidationStarts() async throws {
        for invalidationFails in [true, false] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let keys = MemoryApprovalKeyStore()
            let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
            let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let source = try fixture().source
            let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
            let host = SafariApprovalVaultHost(
                vault: vault, defaults: defaults,
                integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
                reconciliationQueue: reconciliationQueue, sourceSnapshot: { source }
            )
            host.start(backgroundTask: { _ in {} })
            reconciliationQueue.sync {}
            let original = try XCTUnwrap(vault.reviewCatalog()?.identity)
            var startedWriting = false
            reconciliationQueue.suspend()
            do {
                defer { reconciliationQueue.resume() }
                if invalidationFails { keys.removeError = SafariApprovalVault.Error.keychainFailure(errSecIO) }
                do {
                    try await host.performSourceMutation { willMutateSource -> Void in
                        try willMutateSource()
                        startedWriting = true
                        XCTAssertNil(vault.reviewCatalog())
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    XCTFail("Mutation must fail")
                } catch {
                    if invalidationFails {
                        XCTAssertEqual(error as? SafariApprovalVault.Error, .unavailable)
                    } else {
                        XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
                    }
                }
                XCTAssertEqual(startedWriting, !invalidationFails)
                XCTAssertNil(vault.reviewCatalog())
                XCTAssertEqual(try Data(contentsOf: url), Data())
                keys.removeError = nil
            }
            reconciliationQueue.sync {}
            let recovered = try XCTUnwrap(vault.reviewCatalog()?.identity)
            XCTAssertNotEqual(recovered.generation, original.generation)
            XCTAssertEqual(recovered.catalogData, original.catalogData)
            XCTAssertEqual(keys.keys.count, 1)
        }
    }

    @MainActor
    func testHostStartDefersContendedReconciliationAndCoalescesRetries() throws {
        let url = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("coordination-lock"))
        }
        let vault = SafariApprovalVault(fileURL: url, keyStore: MemoryApprovalKeyStore())
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        var retries = [DispatchWorkItem]()
        var sourceReads = 0
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            reconciliationQueue: reconciliationQueue,
            scheduleReconciliationRetry: { retries.append($0) },
            sourceSnapshot: {
                XCTAssertFalse(Thread.isMainThread)
                sourceReads += 1
                return source
            }
        )
        let lease = try vault.acquireCoordinationLease()
        defer { lease.release() }

        let startedAt = ContinuousClock.now
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        host.reconcile()
        reconciliationQueue.sync {}
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
        XCTAssertEqual(sourceReads, 0)
        XCTAssertEqual(retries.count, 1)
        XCTAssertNil(vault.reviewCatalog())

        let firstRetry = retries[0]
        reconciliationQueue.async(execute: firstRetry)
        reconciliationQueue.sync {}
        XCTAssertEqual(sourceReads, 0)
        XCTAssertEqual(retries.count, 2)
        reconciliationQueue.async(execute: firstRetry)
        reconciliationQueue.sync {}
        XCTAssertEqual(retries.count, 2)

        lease.release()
        let secondRetry = retries[1]
        reconciliationQueue.async(execute: secondRetry)
        reconciliationQueue.sync {}
        XCTAssertEqual(sourceReads, 1)
        XCTAssertNotNil(vault.reviewCatalog())
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        XCTAssertEqual(sourceReads, 1)
    }

    @MainActor
    func testForegroundReconciliationRetriesAfterMainActorReleasesExecutionLease()
        async throws {
        let url = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("coordination-lock"))
        }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: MemoryApprovalKeyStore(),
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        let reconciled = expectation(description: "Reconciled after execution lease release")
        var sourceReads = 0
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: {
                XCTAssertFalse(Thread.isMainThread)
                sourceReads += 1
                if sourceReads == 2 { reconciled.fulfill() }
                return source
            }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let original = try XCTUnwrap(vault.reviewCatalog()?.identity)
        let accessValue = await vault.unlockSignerForTesting(reason: "Approve")
        let access = try XCTUnwrap(accessValue)
        let leaseValue = await access.takeCommitLease()
        let lease = try XCTUnwrap(leaseValue)
        defer { lease.release() }

        let startedAt = ContinuousClock.now
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
        XCTAssertEqual(sourceReads, 1)
        XCTAssertEqual(vault.reviewCatalog()?.identity, original)

        await Task { @MainActor in lease.release() }.value
        await fulfillment(of: [reconciled], timeout: 2)
        reconciliationQueue.sync {}
        XCTAssertEqual(sourceReads, 2)
        XCTAssertEqual(vault.reviewCatalog()?.identity, original)
    }

    @MainActor
    func testSuccessfulHostWorkCancelsDeferredReconciliation() async throws {
        for mutate in [false, true] {
            let url = temporaryURL()
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: url.appendingPathExtension("coordination-lock"))
            }
            let vault = SafariApprovalVault(fileURL: url, keyStore: MemoryApprovalKeyStore())
            let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let source = try fixture().source
            var retries = [DispatchWorkItem]()
            var sourceReads = 0
            let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
            let host = SafariApprovalVaultHost(
                vault: vault,
                defaults: defaults,
                integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
                reconciliationQueue: reconciliationQueue,
                scheduleReconciliationRetry: { retries.append($0) },
                sourceSnapshot: {
                    sourceReads += 1
                    return source
                }
            )
            host.start(backgroundTask: { _ in {} })
            reconciliationQueue.sync {}
            let lease = try vault.acquireCoordinationLease()
            defer { lease.release() }
            host.reconcile()
            reconciliationQueue.sync {}
            let retry = try XCTUnwrap(retries.first)
            XCTAssertEqual(retries.count, 1)
            lease.release()

            if mutate {
                try await host.performSourceMutation(preparing: {}) { _ in
                    XCTAssertNil(vault.reviewCatalog())
                }
            } else {
                host.reconcile()
            }
            reconciliationQueue.sync {}
            XCTAssertTrue(retry.isCancelled)
            XCTAssertEqual(sourceReads, 2)
            reconciliationQueue.sync { retry.perform() }
            XCTAssertEqual(sourceReads, 2)
            XCTAssertNotNil(vault.reviewCatalog())
        }
    }

    @MainActor
    func testSourceMutationsRevokeImmediatelyAndCoalesceBackgroundPublication()
        async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 4, count: 32) }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var source: SafariApprovalSourceSnapshot? = try fixture().source
        let replacement = try mnemonicFixture().source
        var sourceReads = 0
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: {
                XCTAssertFalse(Thread.isMainThread)
                sourceReads += 1
                return source
            }
        )

        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let first = try XCTUnwrap(vault.reviewCatalog()?.identity)
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertEqual(vault.reviewCatalog()?.identity, first)

        reconciliationQueue.suspend()
        do {
            defer { reconciliationQueue.resume() }
            for index in 0..<2 {
                let result = try await host.performSourceMutation(preparing: {}) { _ in
                    XCTAssertNil(vault.reviewCatalog())
                    XCTAssertTrue(keys.keys.isEmpty)
                    source = index == 0 ? nil : replacement
                    return "saved"
                }
                XCTAssertEqual(result, "saved")
            }
            XCTAssertNil(vault.reviewCatalog())
            XCTAssertTrue(keys.keys.isEmpty)
            XCTAssertEqual(sourceReads, 2)
        }
        reconciliationQueue.sync {}
        XCTAssertEqual(sourceReads, 3)
        let second = try XCTUnwrap(vault.reviewCatalog()?.identity)
        XCTAssertNotEqual(second.generation, first.generation)
        XCTAssertEqual(second.catalogData, try (replacement.catalog).canonicalData())
    }

    @MainActor
    func testHostAbortsSourceMutationWhenUnavailableTombstoneWriteFails()
        async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var rejectTombstone = false
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 7, count: 32) },
            atomicWrite: { data, destination in
                if rejectTombstone && data.isEmpty {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: destination, options: .atomic)
            }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let initial = try XCTUnwrap(vault.reviewCatalog()?.identity)
        rejectTombstone = true
        var didMutate = false

        do {
            try await host.performSourceMutation(preparing: {}) { _ in didMutate = true }
            XCTFail("Invalidation must fail")
        } catch {
            XCTAssertEqual(error as? SafariApprovalVault.Error, .unavailable)
        }

        XCTAssertFalse(didMutate)
        XCTAssertEqual(vault.reviewCatalog()?.identity, initial)
    }

    @MainActor
    func testFailedInvalidationRepublishesUnchangedSourceWithoutAnotherMutation() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let original = try XCTUnwrap(vault.reviewCatalog()?.identity)

        reconciliationQueue.suspend()
        do {
            defer { reconciliationQueue.resume() }
            keys.removeError = SafariApprovalVault.Error.keychainFailure(errSecIO)
            do {
                try await host.performSourceMutation(preparing: {}) { _ in
                    XCTFail("Source mutation must not run if revocation fails")
                }
                XCTFail("Invalidation must fail")
            } catch {
                XCTAssertEqual(error as? SafariApprovalVault.Error, .unavailable)
            }
            XCTAssertNil(vault.reviewCatalog())
            XCTAssertEqual(try Data(contentsOf: url), Data())
            keys.removeError = nil
        }
        reconciliationQueue.sync {}

        let recovered = try XCTUnwrap(vault.reviewCatalog()?.identity)
        XCTAssertNotEqual(recovered.generation, original.generation)
        XCTAssertEqual(recovered.catalogData, original.catalogData)
        XCTAssertEqual(keys.keys.count, 1)
    }

    func testHostRepublishesSameCatalogWhenEnvelopeDigestChanges() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 10, count: 32) }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let firstGeneration = try XCTUnwrap(
            vault.reviewCatalog()?.identity.generation
        )
        var envelope = try readEnvelope(at: url)
        envelope.accounts[0].tag[0] ^= 0xff
        try writeEnvelope(envelope, at: url)

        host.reconcile()
        reconciliationQueue.sync {}

        let repaired = try XCTUnwrap(vault.reviewCatalog()?.identity)
        XCTAssertNotEqual(repaired.generation, firstGeneration)
    }

    func testHostRepublishesSameCatalogWhenSourcePasswordChanges() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 11, count: 32) }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let first = try XCTUnwrap(vault.reviewCatalog()?.identity)

        let newPassword = Data("changed-password".utf8)
        for index in source.wallets.indices {
            let storedKeyJSON = source.wallets[index].storedKeyJSON
            let key = try XCTUnwrap(WalletStoredKey.importJSON(json: storedKeyJSON))
            var secret = try XCTUnwrap(key.decryptPrivateKey(password: source.password))
            defer { secret.resetBytes(in: 0..<secret.count) }
            let encrypted = try XCTUnwrap(EncryptedPayload.encrypt(
                payload: secret,
                password: newPassword
            ))
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: storedKeyJSON) as? [String: Any]
            )
            object["crypto"] = encrypted.jsonObject()
            object["Crypto"] = nil
            source.wallets[index].storedKeyJSON = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        }
        source.password = newPassword
        host.reconcile()
        reconciliationQueue.sync {}

        let repaired = try XCTUnwrap(vault.reviewCatalog()?.identity)
        XCTAssertNotEqual(repaired.generation, first.generation)
        XCTAssertEqual(repaired.catalogData, first.catalogData)
    }

    func testPublicationRejectsWrongPassword() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 18, count: 32) }
        )
        var source = try fixture().source
        source.password = Data("wrong-password".utf8)
        XCTAssertThrowsError(try vault.publish(
            source: source,
            integrityKey: integrityKey
        )) { error in
            XCTAssertEqual(error as? SafariApprovalVault.Error, .invalidCatalog)
        }
        XCTAssertTrue(keys.keys.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

    }

    func testHostRepublishesSameCatalogWhenStoredKeyJSONChanges() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 12, count: 32) }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let first = try XCTUnwrap(vault.reviewCatalog()?.identity)
        let originalJSON = source.wallets[0].storedKeyJSON
        let object = try JSONSerialization.jsonObject(with: originalJSON)
        let rewrittenJSON = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        XCTAssertNotEqual(rewrittenJSON, originalJSON)
        XCTAssertNotNil(WalletStoredKey.importJSON(json: rewrittenJSON))

        source.wallets[0].storedKeyJSON = rewrittenJSON
        host.reconcile()
        reconciliationQueue.sync {}

        let repaired = try XCTUnwrap(vault.reviewCatalog()?.identity)
        XCTAssertNotEqual(repaired.generation, first.generation)
        XCTAssertEqual(repaired.catalogData, first.catalogData)
    }

    func testCurrentPublicationSurvivesUnrelatedMetadataSynchronizationFailure()
        async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try fixture()
        var rejectSynchronization = false
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            synchronizeDefaults: { value in
                rejectSynchronization ? false : value.synchronize()
            },
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { fixture.source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let initial = try XCTUnwrap(vault.reviewCatalog()?.identity)
        let envelope = try Data(contentsOf: url)
        let unlocked = await vault.unlockSignerForTesting(reason: "Already approved")
        let access = try XCTUnwrap(unlocked)
        rejectSynchronization = true

        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertEqual(vault.reviewCatalog()?.identity, initial)
        XCTAssertEqual(try Data(contentsOf: url), envelope)
        XCTAssertTrue(keys.keys.keys.contains { $0.generation == initial.generation })
        try await assertSigningAccessForTesting(access, walletID: "wallet", account: fixture.account, expectedSuccess: true)
    }

    @MainActor
    func testFailedSourceMutationReconcilesAndPreservesErrorWhenMetadataSynchronizationFails()
        async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var stores = 0
        keys.onStore = { _ in stores += 1 }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 13, count: 32) }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        var rejectMetadataUpdates = false
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            synchronizeDefaults: { value in
                if rejectMetadataUpdates {
                    return false
                }
                return value.synchronize()
            },
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let first = try XCTUnwrap(vault.reviewCatalog()?.identity)
        XCTAssertEqual(stores, 1)
        rejectMetadataUpdates = true
        var mutations = 0

        do {
            try await host.performSourceMutation(preparing: {}) { _ in
                mutations += 1
                XCTAssertEqual(stores, 1)
                XCTAssertNil(vault.reviewCatalog())
                throw CocoaError(.fileWriteNoPermission)
            }
            XCTFail("Source mutation must fail")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
        }

        XCTAssertEqual(mutations, 1)
        XCTAssertEqual(source.password, try fixture().source.password)
        XCTAssertEqual(
            source.wallets.map(\.storedKeyJSON),
            try fixture().source.wallets.map(\.storedKeyJSON)
        )

        reconciliationQueue.sync {}

        let recovered = try XCTUnwrap(vault.reviewCatalog()?.identity)
        XCTAssertEqual(stores, 2)
        XCTAssertNotEqual(recovered.generation, first.generation)
        XCTAssertEqual(recovered.catalogData, first.catalogData)
    }

    @MainActor
    func testSourceMutationRemainsAvailableDuringPersistentMetadataSynchronizationFailure()
        async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var stores = 0
        keys.onStore = { _ in stores += 1 }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = try fixture()
        let replacement = try mnemonicFixture()
        var source = original.source
        var rejectSynchronization = false
        var synchronizationFailures = 0
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            synchronizeDefaults: { value in
                if rejectSynchronization {
                    synchronizationFailures += 1
                    return false
                }
                return value.synchronize()
            },
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: {
                return source
            }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let originalIdentity = try XCTUnwrap(vault.reviewCatalog()?.identity)
        let unlocked = await vault.unlockSignerForTesting(reason: "Before metadata failure")
        let previousAccess = try XCTUnwrap(unlocked)
        try await assertSigningAccessForTesting(previousAccess, walletID: "wallet", account: original.account, expectedSuccess: true)
        rejectSynchronization = true
        var mutations = 0

        let result = try await host.performSourceMutation(preparing: {}) { _ in
            mutations += 1
            XCTAssertTrue(keys.keys.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), Data())
            source = replacement.source
            return "saved"
        }

        XCTAssertEqual(result, "saved")
        XCTAssertEqual(mutations, 1)
        reconciliationQueue.sync {}
        XCTAssertEqual(stores, 2)
        XCTAssertGreaterThan(synchronizationFailures, 0)
        let current = try XCTUnwrap(vault.reviewCatalog()?.identity)
        let envelope = try Data(contentsOf: url)
        let metadata = try XCTUnwrap(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ))
        XCTAssertNotEqual(current.generation, originalIdentity.generation)
        XCTAssertNotEqual(current.catalogData, originalIdentity.catalogData)
        XCTAssertFalse(previousAccess.validateCurrent())
        try await assertSigningAccessForTesting(previousAccess, walletID: "wallet", account: original.account, expectedSuccess: false)
        let previousLease = await previousAccess.takeCommitLease()
        XCTAssertNil(previousLease)
        let replacementUnlock = await vault.unlockSignerForTesting(reason: "During metadata failure")
        let replacementAccess = try XCTUnwrap(replacementUnlock)
        try await assertSigningAccessForTesting(replacementAccess, walletID: "mnemonic-wallet", account: replacement.account, expectedSuccess: true)

        for _ in 0..<2 {
            let previousFailures = synchronizationFailures
            host.reconcile()
            reconciliationQueue.sync {}
            XCTAssertGreaterThan(synchronizationFailures, previousFailures)
            XCTAssertEqual(mutations, 1)
            XCTAssertEqual(stores, 2)
            XCTAssertEqual(vault.reviewCatalog()?.identity, current)
            XCTAssertEqual(try Data(contentsOf: url), envelope)
            XCTAssertEqual(defaults.data(
                forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
            ), metadata)
            XCTAssertTrue(replacementAccess.validateCurrent())
        }

        rejectSynchronization = false
        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertEqual(mutations, 1)
        XCTAssertEqual(stores, 2)
        XCTAssertEqual(vault.reviewCatalog()?.identity, current)
        XCTAssertEqual(try Data(contentsOf: url), envelope)
        let recoveredUnlock = await vault.unlockSignerForTesting(reason: "After metadata recovery")
        let recoveredAccess = try XCTUnwrap(recoveredUnlock)
        try await assertSigningAccessForTesting(recoveredAccess, walletID: "mnemonic-wallet", account: replacement.account, expectedSuccess: true)
        XCTAssertFalse(keys.keys.keys.contains { $0.generation == originalIdentity.generation })
        XCTAssertFalse(previousAccess.validateCurrent())
        let replayedLease = await previousAccess.takeCommitLease()
        XCTAssertNil(replayedLease)
    }

    @MainActor
    func testSourceMutationImmediatelyRecoversAfterTransientMetadataSynchronizationFailure()
        async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var stores = 0
        keys.onStore = { _ in stores += 1 }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = try fixture()
        let replacement = try mnemonicFixture()
        var source = original.source
        var failNextSynchronization = false
        var synchronizationFailures = 0
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            synchronizeDefaults: { value in
                if failNextSynchronization {
                    failNextSynchronization = false
                    synchronizationFailures += 1
                    return false
                }
                return value.synchronize()
            },
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let first = try XCTUnwrap(vault.reviewCatalog()?.identity)
        let originalUnlock = await vault.unlockSignerForTesting(reason: "Before mutation")
        let previousAccess = try XCTUnwrap(originalUnlock)
        failNextSynchronization = true
        var mutations = 0

        let result = try await host.performSourceMutation(preparing: {}) { _ in
            mutations += 1
            XCTAssertTrue(keys.keys.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), Data())
            source = replacement.source
            return "saved"
        }

        XCTAssertEqual(result, "saved")
        XCTAssertEqual(mutations, 1)
        reconciliationQueue.sync {}
        XCTAssertEqual(synchronizationFailures, 1)
        XCTAssertEqual(stores, 2)
        let current = try XCTUnwrap(vault.reviewCatalog()?.identity)
        XCTAssertNotEqual(current.generation, first.generation)
        XCTAssertNotEqual(current.catalogData, first.catalogData)
        XCTAssertNotNil(defaults.data(forKey: "SafariApprovalVault.hostPublicationMetadata.v1"))
        XCTAssertFalse(keys.keys.keys.contains { $0.generation == first.generation })
        XCTAssertFalse(previousAccess.validateCurrent())
        let previousLease = await previousAccess.takeCommitLease()
        XCTAssertNil(previousLease)
        let replacementUnlock = await vault.unlockSignerForTesting(reason: "After mutation")
        let access = try XCTUnwrap(replacementUnlock)
        try await assertSigningAccessForTesting(access, walletID: "mnemonic-wallet", account: replacement.account, expectedSuccess: true)
    }

    @MainActor
    func testSourceMutationRevokesCachedVaultEvenWithoutReconciliation()
        async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var source: SafariApprovalSourceSnapshot? = try fixture().source
        var synchronizationAttempts = 0
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            synchronizeDefaults: { value in
                synchronizationAttempts += 1
                return value.synchronize()
            },
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let cachedEnvelope = try Data(contentsOf: url)
        let unlocked = await vault.unlockSignerForTesting(reason: "Before mutation")
        let priorAccess = try XCTUnwrap(unlocked)
        let attemptsBeforeRevocation = synchronizationAttempts
        reconciliationQueue.suspend()
        defer {
            reconciliationQueue.resume()
            reconciliationQueue.sync {}
        }

        keys.removeError = SafariApprovalVault.Error.keychainFailure(errSecIO)
        do {
            try await host.performSourceMutation(preparing: {}) { _ in
                XCTFail("Source mutation must not run if key revocation fails")
                source = nil
            }
            XCTFail("Invalidation must fail")
        } catch {
            XCTAssertEqual(error as? SafariApprovalVault.Error, .unavailable)
        }
        XCTAssertNotNil(source)
        XCTAssertEqual(synchronizationAttempts, attemptsBeforeRevocation)

        keys.removeError = nil
        do {
            try await host.performSourceMutation(preparing: {}) { _ in
                XCTAssertTrue(keys.keys.isEmpty)
                source = nil
                throw SafariApprovalVault.Error.unavailable
            }
            XCTFail("Source mutation must fail")
        } catch {
            XCTAssertEqual(error as? SafariApprovalVault.Error, .unavailable)
        }
        XCTAssertNil(source)
        try cachedEnvelope.write(to: url, options: .atomic)

        XCTAssertNil(vault.reviewCatalog())
        let replayedAccess = await vault.unlockSignerForTesting(reason: "After mutation")
        XCTAssertNil(replayedAccess)
        XCTAssertFalse(priorAccess.validateCurrent())
        let priorLease = await priorAccess.takeCommitLease()
        XCTAssertNil(priorLease)
    }

    @MainActor
    func testPublicationRevokesOldKeysBeforeSourceMutation()
        async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var events = [String]()
        keys.onStore = { _ in events.append("store") }
        keys.onRemove = { events.append("delete") }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 14, count: 32) },
            atomicWrite: { data, destination in
                events.append(data.isEmpty ? "tombstone" : "envelope")
                try data.write(to: destination, options: .atomic)
            }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            synchronizeDefaults: { value in
                events.append("metadata")
                return value.synchronize()
            },
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        events.removeAll()

        try await host.performSourceMutation(preparing: {}) { _ in
            events.append("source")
            XCTAssertNil(vault.reviewCatalog())
        }
        reconciliationQueue.sync {}

        let sourceIndex = try XCTUnwrap(events.firstIndex(of: "source"))
        let firstDeletionIndex = try XCTUnwrap(events.firstIndex(of: "delete"))
        let storeIndex = try XCTUnwrap(events.firstIndex(of: "store"))
        let envelopeIndex = try XCTUnwrap(events.firstIndex(of: "envelope"))
        let metadataIndex = try XCTUnwrap(events.lastIndex(of: "metadata"))
        let lastDeletionIndex = try XCTUnwrap(events.lastIndex(of: "delete"))
        XCTAssertEqual(events.first, "tombstone")
        XCTAssertLessThan(firstDeletionIndex, sourceIndex)
        XCTAssertLessThan(sourceIndex, storeIndex)
        XCTAssertLessThan(storeIndex, envelopeIndex)
        XCTAssertLessThan(envelopeIndex, metadataIndex)
        XCTAssertLessThan(lastDeletionIndex, storeIndex)
        XCTAssertEqual(keys.keys.count, 1)
        XCTAssertNotNil(vault.reviewCatalog())
    }

    func testPublicationStoreFailureStaysUnavailableAndRecovers() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 15, count: 32) }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        try reformatStoredKey(in: &source)
        keys.storeError = SafariApprovalVault.Error.keychainFailure(errSecIO)

        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertNil(vault.reviewCatalog())
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertTrue(keys.keys.isEmpty)
        keys.storeError = nil
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertNotNil(vault.reviewCatalog())
        XCTAssertEqual(keys.keys.count, 1)
    }

    func testPublicationEnvelopeWriteFailureStaysUnavailableAndRecovers()
        async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var rejectEnvelope = false
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 16, count: 32) },
            atomicWrite: { data, destination in
                if rejectEnvelope && !data.isEmpty {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: destination, options: .atomic)
            }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let cachedEnvelope = try Data(contentsOf: url)
        try reformatStoredKey(in: &source)
        rejectEnvelope = true

        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertNil(vault.reviewCatalog())
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertTrue(keys.keys.isEmpty)
        try cachedEnvelope.write(to: url, options: .atomic)
        XCTAssertNil(vault.reviewCatalog())
        let replayedAccess = await vault.unlockSignerForTesting(reason: "After publication failure")
        XCTAssertNil(replayedAccess)
        rejectEnvelope = false
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertNotNil(vault.reviewCatalog())
        XCTAssertEqual(keys.keys.count, 1)
    }

    func testFailedFailClosedTombstoneRetiresApprovalKeysAsFallback() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var rejectTombstone = false
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 20, count: 32) },
            atomicWrite: { data, destination in
                if rejectTombstone && data.isEmpty {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: destination, options: .atomic)
            }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        XCTAssertEqual(keys.keys.count, 1)
        try reformatStoredKey(in: &source)
        rejectTombstone = true

        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertNil(vault.reviewCatalog())
        XCTAssertTrue(keys.keys.isEmpty)
        rejectTombstone = false
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertNotNil(vault.reviewCatalog())
        XCTAssertEqual(keys.keys.count, 1)
    }

    func testInitialPublicationSurvivesMetadataFailureAndSynchronizesWithoutRotation()
        async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var stores = 0
        keys.onStore = { _ in stores += 1 }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try fixture()
        var rejectSynchronization = true
        var synchronizedMetadata: Data?
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            synchronizeDefaults: { value in
                guard !rejectSynchronization else { return false }
                synchronizedMetadata = value.data(
                    forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
                )
                return value.synchronize()
            },
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { fixture.source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let initial = try XCTUnwrap(vault.reviewCatalog()?.identity)
        let envelope = try Data(contentsOf: url)
        let metadata = try XCTUnwrap(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ))
        let unlocked = await vault.unlockSignerForTesting(reason: "During metadata failure")
        let access = try XCTUnwrap(unlocked)
        try await assertSigningAccessForTesting(access, walletID: "wallet", account: fixture.account, expectedSuccess: true)
        XCTAssertNil(synchronizedMetadata)
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertEqual(stores, 1)
        XCTAssertEqual(vault.reviewCatalog()?.identity, initial)
        XCTAssertEqual(try Data(contentsOf: url), envelope)
        XCTAssertTrue(keys.keys.keys.contains { $0.generation == initial.generation })

        rejectSynchronization = false
        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertEqual(synchronizedMetadata, metadata)
        XCTAssertEqual(stores, 1)
        XCTAssertEqual(vault.reviewCatalog()?.identity, initial)
        XCTAssertEqual(try Data(contentsOf: url), envelope)
        XCTAssertTrue(access.validateCurrent())
    }

    func testPublicationDeletionFailureStaysUnavailableAndRecovers() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 18, count: 32) }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        try reformatStoredKey(in: &source)
        keys.removeError = SafariApprovalVault.Error.keychainFailure(errSecIO)

        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertNil(vault.reviewCatalog())
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertEqual(keys.keys.count, 1)
        keys.removeError = nil
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertNotNil(vault.reviewCatalog())
        XCTAssertEqual(keys.keys.count, 1)
    }

    func testLockedKeychainPreservesPublicationAndRetriesAfterUnlock() throws {
        for sourceIsLocked in [true, false] {
            let url = temporaryURL()
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: url.appendingPathExtension("coordination-lock"))
            }
            let keys = MemoryApprovalKeyStore()
            let integrityKeys = MemoryApprovalIntegrityKeyStore(key: integrityKey)
            let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
            let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let source = try fixture().source
            var isLocked = false
            var sourceReads = 0
            let notifications = NotificationCenter()
            let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
            let host = SafariApprovalVaultHost(
                vault: vault,
                defaults: defaults,
                integrityKeyStore: integrityKeys,
                notificationCenter: notifications,
                reconciliationQueue: reconciliationQueue,
                sourceSnapshot: {
                    sourceReads += 1
                    if sourceIsLocked && isLocked {
                        throw Keychain.KeychainError.failedToRead(errSecInteractionNotAllowed)
                    }
                    return source
                }
            )
            host.start(backgroundTask: { _ in {} })
            reconciliationQueue.sync {}
            let identity = try XCTUnwrap(vault.reviewCatalog()?.identity)
            let envelope = try Data(contentsOf: url)
            let publishedKeys = keys.keys
            let metadataKey = "SafariApprovalVault.hostPublicationMetadata.v1"
            let metadata = try XCTUnwrap(defaults.data(forKey: metadataKey))

            isLocked = true
            if !sourceIsLocked {
                integrityKeys.error = SafariApprovalVault.Error.keychainFailure(errSecInteractionNotAllowed)
            }
            host.reconcile()
            reconciliationQueue.sync {}

            XCTAssertEqual(sourceReads, 2)
            XCTAssertEqual(vault.reviewCatalog()?.identity, identity)
            XCTAssertEqual(try Data(contentsOf: url), envelope)
            XCTAssertEqual(keys.keys, publishedKeys)
            XCTAssertEqual(defaults.data(forKey: metadataKey), metadata)

            isLocked = false
            integrityKeys.error = nil
            notifications.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
            reconciliationQueue.sync {}

            XCTAssertEqual(sourceReads, 3)
            XCTAssertEqual(vault.reviewCatalog()?.identity, identity)
            XCTAssertEqual(try Data(contentsOf: url), envelope)
            XCTAssertEqual(keys.keys, publishedKeys)
            XCTAssertEqual(defaults.data(forKey: metadataKey), metadata)
        }
    }

    func testMissingRotatedAndUnavailableIntegrityKeysFailClosed() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let integrityKeys = MemoryApprovalIntegrityKeyStore(key: integrityKey)
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 19, count: 32) }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try fixture().source
        let reconciliationQueue = DispatchQueue(label: "SafariApprovalVaultHostTests.reconciliation")
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: integrityKeys,
            reconciliationQueue: reconciliationQueue,
            sourceSnapshot: { source }
        )
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        let first = try XCTUnwrap(vault.reviewCatalog()?.identity)

        integrityKeys.key = nil
        host.reconcile()
        reconciliationQueue.sync {}
        let afterMissing = try XCTUnwrap(
            vault.reviewCatalog()?.identity
        )
        XCTAssertNotEqual(afterMissing.generation, first.generation)

        integrityKeys.key = Data(repeating: 0xd0, count: 32)
        host.reconcile()
        reconciliationQueue.sync {}
        let afterRotation = try XCTUnwrap(
            vault.reviewCatalog()?.identity
        )
        XCTAssertNotEqual(
            afterRotation.generation,
            afterMissing.generation
        )

        integrityKeys.error = SafariApprovalVault.Error.keychainFailure(errSecIO)
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertNil(vault.reviewCatalog())
        XCTAssertEqual(try Data(contentsOf: url), Data())

        integrityKeys.error = nil
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertNotNil(vault.reviewCatalog())
        XCTAssertEqual(keys.keys.count, 1)
    }

    func testEverySafariTargetExcludesSourceWalletKeychain() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mobilePaths = [
            "Safari iOS/Safari iOS.entitlements",
            "Safari visionOS/Safari visionOS.entitlements",
        ]
        for relativePath in mobilePaths {
            let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
            let plist = try XCTUnwrap(
                PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any]
            )
            let groups = try XCTUnwrap(
                plist["keychain-access-groups"] as? [String]
            )
            XCTAssertFalse(groups.contains("$(AppIdentifierPrefix)org.lil.keychain"))
            XCTAssertTrue(groups.contains(
                "$(AppIdentifierPrefix)org.lil.wallet.safari-approval"
            ))
            XCTAssertEqual(Set(groups), [
                "$(AppIdentifierPrefix)org.lil.wallet.safari-approval",
                "$(AppIdentifierPrefix)org.lil.wallet.rpc-auth",
            ])
        }

        let macData = try Data(contentsOf: root.appendingPathComponent(
            "Safari macOS/Safari.entitlements"
        ))
        let macPlist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: macData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(
            macPlist["keychain-access-groups"] as? [String],
            ["$(AppIdentifierPrefix)org.lil.wallet.rpc-auth"]
        )

        let trustedTargets: [(String, Set<String>)] = [
            (
                "App iOS/Wallet iOS.entitlements",
                [
                    "$(AppIdentifierPrefix)org.lil.keychain",
                    "$(AppIdentifierPrefix)org.lil.wallet.safari-approval",
                    "$(AppIdentifierPrefix)org.lil.wallet.rpc-auth",
                ]
            ),
            (
                "App visionOS/Big Wallet visionOS.entitlements",
                [
                    "$(AppIdentifierPrefix)org.lil.keychain",
                    "$(AppIdentifierPrefix)org.lil.wallet.safari-approval",
                    "$(AppIdentifierPrefix)org.lil.wallet.rpc-auth",
                ]
            ),
            (
                "App macOS/Supporting Files/Wallet macOS.entitlements",
                [
                    "$(AppIdentifierPrefix)org.lil.keychain",
                    "$(AppIdentifierPrefix)org.lil.wallet.rpc-auth",
                ]
            ),
            (
                "Big Wallet Ambient/Big Wallet Ambient.entitlements",
                [
                    "$(AppIdentifierPrefix)org.lil.keychain",
                    "$(AppIdentifierPrefix)org.lil.wallet.rpc-auth",
                ]
            ),
        ]
        for (relativePath, expectedGroups) in trustedTargets {
            let data = try Data(
                contentsOf: root.appendingPathComponent(relativePath)
            )
            let plist = try XCTUnwrap(
                PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any]
            )
            XCTAssertEqual(
                Set(try XCTUnwrap(
                    plist["keychain-access-groups"] as? [String]
                )),
                expectedGroups,
                relativePath
            )
        }
    }
}

private final class ProtectedApprovalKeychainFixture {
    var keys = [String: Data]()
    var events = [String]()
    var availabilityStatus: OSStatus = errSecInteractionNotAllowed
    var loadStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    var addStatus: ((String) -> OSStatus)?
    var availabilityStatuses = [String: OSStatus]()
    private(set) var availabilityReads = 0
    private(set) var protectedKeyReads = 0

    lazy var store = SafariApprovalKeychainStore(
        add: { [unowned self] query, _ in
            events.append("add")
            let query = query as NSDictionary
            guard let account = query[kSecAttrAccount] as? String,
                  let data = query[kSecValueData] as? Data else {
                return errSecParam
            }
            XCTAssertNotNil(query[kSecAttrAccessControl])
            XCTAssertEqual(query[kSecAttrService] as? String, SafariApprovalKeychainStore.service)
            XCTAssertEqual(query[kSecAttrAccessGroup] as? String, SafariApprovalKeychainStore.accessGroup)
            XCTAssertNil(keys[account])
            if let status = addStatus?(account), status != errSecSuccess { return status }
            keys[account] = data
            return errSecSuccess
        },
        copyMatching: { [unowned self] query, result in
            let query = query as NSDictionary
            guard let context = query[kSecUseAuthenticationContext] as? LAContext else {
                XCTFail("Approval keys require an explicit authentication context")
                return errSecParam
            }
            if query[kSecMatchLimit] as? String == kSecMatchLimitAll as String {
                availabilityReads += 1
                XCTAssertNil(query[kSecAttrAccount])
                XCTAssertNil(query[kSecReturnData])
                XCTAssertEqual(query[kSecReturnAttributes] as? Bool, true)
                XCTAssertTrue(context.interactionNotAllowed)
                guard availabilityStatus == errSecSuccess else { return availabilityStatus }
                result?.pointee = keys.keys.map { [kSecAttrAccount as String: $0] } as CFArray
                return keys.isEmpty ? errSecItemNotFound : errSecSuccess
            }
            guard let account = query[kSecAttrAccount] as? String else {
                XCTFail("Account key queries require an exact identity")
                return errSecParam
            }
            guard let data = keys[account] else { return errSecItemNotFound }
            if query[kSecReturnData] as? Bool == true {
                protectedKeyReads += 1
                XCTAssertFalse(context.interactionNotAllowed)
                guard loadStatus == errSecSuccess else { return loadStatus }
                result?.pointee = data as CFData
                return errSecSuccess
            }
            availabilityReads += 1
            XCTAssertEqual(query[kSecReturnAttributes] as? Bool, true)
            XCTAssertTrue(context.interactionNotAllowed)
            return availabilityStatuses[account] ?? availabilityStatus
        },
        delete: { [unowned self] query in
            events.append("delete")
            let query = query as NSDictionary
            XCTAssertEqual(query[kSecAttrService] as? String, SafariApprovalKeychainStore.service)
            XCTAssertEqual(query[kSecAttrAccessGroup] as? String, SafariApprovalKeychainStore.accessGroup)
            XCTAssertNil(query[kSecAttrAccount])
            guard deleteStatus == errSecSuccess else { return deleteStatus }
            keys.removeAll()
            return errSecSuccess
        }
    )
}

private final class MemoryApprovalKeyStore: SafariApprovalKeyStoring {
    var keys = [SafariApprovalKeyIdentity: Data]()
    var availabilityOverrides = [SafariApprovalKeyIdentity: SafariApprovalKeyAvailability]()
    var loadedIdentities = [SafariApprovalKeyIdentity]()
    var availabilityRequests = [[SafariApprovalKeyIdentity]]()
    var loadedContext: LAContext?
    var onLoad: (() -> Void)?
    var onAvailability: (() -> Void)?
    var onStore: ((SafariApprovalKeyIdentity) -> Void)?
    var onRemove: (() -> Void)?
    var storeError: Swift.Error?
    var removeError: Swift.Error?

    func store(_ key: Data, identity: SafariApprovalKeyIdentity) throws {
        onStore?(identity)
        if let storeError { throw storeError }
        keys[identity] = key
    }

    func load(identity: SafariApprovalKeyIdentity, context: LAContext) throws -> Data {
        loadedContext = context
        loadedIdentities.append(identity)
        guard let key = keys[identity] else {
            throw SafariApprovalVault.Error.invalidKey
        }
        onLoad?()
        return key
    }

    func availability(identities: [SafariApprovalKeyIdentity]) -> [SafariApprovalKeyIdentity: SafariApprovalKeyAvailability] {
        availabilityRequests.append(identities)
        onAvailability?()
        return Dictionary(uniqueKeysWithValues: identities.map { identity in
            (identity, availabilityOverrides[identity] ?? (keys[identity] == nil ? .missing : .present))
        })
    }

    func removeAll() throws {
        onRemove?()
        if let removeError { throw removeError }
        keys.removeAll()
    }
}

private final class MemoryApprovalIntegrityKeyStore:
    SafariApprovalIntegrityKeyStoring {

    var key: Data?
    var error: Swift.Error?
    private var nextByte: UInt8 = 0xc0

    init(key: Data?) {
        self.key = key
    }

    func loadOrCreate() throws -> Data {
        if let error { throw error }
        if let key { return key }
        let created = Data(repeating: nextByte, count: 32)
        nextByte &+= 1
        key = created
        return created
    }
}

private final class DerivationRaceWalletSigner: OwnedWalletSigningAccess {
    private let didDerive: () -> Void

    init(account: WalletAccount, didDerive: @escaping () -> Void) {
        self.didDerive = didDerive
    }

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        didDerive()
        return .success(.ethereumSignature("discarded-signature"))
    }

    func invalidate() {}

}
private extension SafariApprovalVault {
    func unlockSignerForTesting(reason: String) async -> WalletSigningSession? {
        guard let selected = reviewCatalog()?.orderedAccounts.first,
              case .unlocked(_, let signer) = await unlockResult(
                  reason: reason,
                  authorization: walletSigningAuthorizationForTesting(approvedAccount: WalletAccountDescriptor(walletID: selected.walletId, account: selected.account))
              ) else { return nil }
        return signer
    }
}
#endif
