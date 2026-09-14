#if os(iOS) || os(visionOS)
import LocalAuthentication
import Security
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
            accounts: SourceWalletAccess.descriptors(for: [wallet])
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
                    accounts: SourceWalletAccess.descriptors(for: [wallet])
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

    private func unlockedAccess(
        source: SafariApprovalSourceSnapshot
    ) throws -> UnlockedWalletAccess {
        try XCTUnwrap(UnlockedWalletAccess(
            catalog: source.catalog,
            generation: UUID(),
            catalogData: SourceWalletAccess.encodeCatalog(source.catalog),
            password: source.password,
            walletRecords: source.wallets.map {
                (id: $0.walletID, data: $0.storedKeyJSON)
            }
        ))
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
                    accounts: SourceWalletAccess.descriptors(for: wallets)
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
            "catalog",
            "ciphertext",
            "generation",
            "header",
            "nonce",
            "tag",
            "version",
        ])
        XCTAssertEqual(envelope["version"] as? Int, 1)
        let catalogJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: SourceWalletAccess.encodeCatalog(fixture.source.catalog)
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
        let catalogAccess = try XCTUnwrap(vault.catalogAccess())
        XCTAssertEqual(catalogAccess.orderedAccounts.count, 1)
        XCTAssertNil(catalogAccess.privateKey(
            walletID: "wallet",
            account: catalogAccess.orderedAccounts[0].account
        ))

        let unlockedValue = await vault.unlock(reason: "Approve")
        let unlocked = try XCTUnwrap(unlockedValue)
        XCTAssertEqual(capabilityChecks, 1)
        XCTAssertEqual(authenticationAttempts, 1)
        XCTAssertTrue(capabilityContext === authenticationContext)
        XCTAssertTrue(authenticationContext === keys.loadedContext)
        XCTAssertEqual(unlocked.catalogIdentity, catalogAccess.catalogIdentity)
        XCTAssertNotNil(unlocked.privateKey(
            walletID: "wallet",
            account: fixture.account
        ))
        unlocked.invalidate()
        XCTAssertNil(unlocked.privateKey(
            walletID: "wallet",
            account: fixture.account
        ))
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
        keys.keys[replacementGeneration] = try XCTUnwrap(keys.keys[originalGeneration])
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

        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity.generation, replacementGeneration)
        var loadedKey = false
        keys.onLoad = { loadedKey = true }
        let unlocked = await vault.unlock(reason: "Approve")
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

        let unlockedValue = await vault.unlock(reason: "Approve")
        let unlocked = try XCTUnwrap(unlockedValue)

        XCTAssertNotNil(unlocked.privateKey(
            walletID: "mnemonic-wallet",
            account: fixture.account
        ))
    }

    func testPublicationAndSelectedSignerRejectUnownedMnemonicAccount() throws {
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
                accounts: SourceWalletAccess.descriptors(for: [wallet])
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
        XCTAssertTrue(publicationEvents.isEmpty)
        XCTAssertTrue(keys.keys.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let access = try unlockedAccess(source: source)
        defer { access.invalidate() }
        XCTAssertNil(access.privateKey(
            walletID: wallet.id,
            account: try XCTUnwrap(wallet.accounts.first)
        ))
    }

    func testUnlockedAccessDerivesEthereumAndSolanaSignersAndChecksSelectedIdentity()
        throws {
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
                    SourceWalletAccess.descriptors(for: [importedSolanaWallet])
            ),
            password: fixture.source.password,
            wallets: fixture.source.wallets + [SafariApprovalWalletRecord(
                walletID: importedSolanaWallet.id,
                storedKeyJSON: try XCTUnwrap(importedSolanaKey.exportJSON())
            )]
        )
        let access = try unlockedAccess(source: source)
        defer { access.invalidate() }
        XCTAssertEqual(access.orderedAccounts.count, 4)

        for selected in access.orderedAccounts {
            let account = selected.account
            let privateKey = try XCTUnwrap(access.privateKey(
                walletID: selected.walletId,
                account: account
            ))
            XCTAssertEqual(
                account.coin.normalizedAddress(WalletCrypto.addressFromPublicKeyData(
                    privateKey.publicKeyData(coin: account.coin),
                    coin: account.coin
                )),
                account.coin.normalizedAddress(account.address)
            )
            XCTAssertNil(access.privateKey(walletID: "missing-wallet", account: account))
            let otherWallet = try XCTUnwrap(access.orderedAccounts.first {
                $0.walletId != selected.walletId
            })
            XCTAssertNil(access.privateKey(walletID: otherWallet.walletId, account: account))

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
                XCTAssertNil(access.privateKey(
                    walletID: selected.walletId,
                    account: mismatchedAccount
                ))
            }
        }
    }

    func testUnrelatedUndecryptableWalletDoesNotBlockSelectedSignerButCannotPublish()
        throws {
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
                    SourceWalletAccess.descriptors(for: [unrelatedWallet])
            ),
            password: fixture.source.password,
            wallets: fixture.source.wallets + [SafariApprovalWalletRecord(
                walletID: unrelatedWallet.id,
                storedKeyJSON: try XCTUnwrap(unrelatedKey.exportJSON())
            )]
        )
        let access = try unlockedAccess(source: source)
        defer { access.invalidate() }
        XCTAssertNotNil(access.privateKey(walletID: "wallet", account: fixture.account))
        XCTAssertNil(access.privateKey(
            walletID: unrelatedWallet.id,
            account: try XCTUnwrap(unrelatedWallet.accounts.first)
        ))
        XCTAssertNotNil(access.privateKey(walletID: "wallet", account: fixture.account))

        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
        XCTAssertThrowsError(try vault.publish(source: source, integrityKey: integrityKey)) {
            XCTAssertEqual($0 as? SafariApprovalVault.Error, .invalidCatalog)
        }
        XCTAssertTrue(keys.keys.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnownedSiblingDoesNotBlockSelectedMnemonicSignerButCannotPublish()
        throws {
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
            catalog: WalletAccountCatalog(accounts: SourceWalletAccess.descriptors(for: wallets)),
            password: fixture.source.password,
            wallets: records
        )
        let access = try unlockedAccess(source: source)
        defer { access.invalidate() }
        let selected = fixture.accounts[0]
        XCTAssertNotNil(access.privateKey(walletID: selected.walletId, account: selected.account))
        XCTAssertNil(access.privateKey(
            walletID: wallets[0].id,
            account: wallets[0].accounts[1]
        ))
        XCTAssertNotNil(access.privateKey(walletID: selected.walletId, account: selected.account))

        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(fileURL: url, keyStore: keys)
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

        let result = await vault.unlockResult(reason: "Approve")

        guard case .canceled = result else {
            return XCTFail("Authentication cancellation must remain distinct")
        }
        XCTAssertEqual(capabilityChecks, 1)
        XCTAssertEqual(authenticationAttempts, 1)
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
        let originalGeneration = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity.generation)
        keys.onLoad = {
            keys.onLoad = nil
            _ = try? vault.publish(
                source: source,
                integrityKey: self.integrityKey
            )
        }

        let result = await vault.unlockResult(reason: "Approve")

        guard case .unavailable = result else {
            return XCTFail("A rotated envelope must invalidate the unlock")
        }
        let replacementGeneration = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity.generation)
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
        let unlockedValue = await vault.unlock(reason: "Approve")
        let unlocked = try XCTUnwrap(unlockedValue)

        try keys.removeAll()

        XCTAssertNil(vault.catalogAccess())
        XCTAssertTrue(unlocked.orderedAccounts.isEmpty)
        XCTAssertNil(unlocked.privateKey(
            walletID: "wallet",
            account: fixture.account
        ))
    }

    func testRequestScopeRechecksGenerationAfterPrivateKeyDerivation() throws {
        let fixture = try fixture()
        var isCurrent = true
        let underlying = DerivationRaceWalletAccess(account: fixture.account) {
            isCurrent = false
        }
        let scoped = RequestScopedWalletAccess(underlying) { isCurrent }

        XCTAssertNil(scoped.privateKey(
            walletID: "wallet",
            account: fixture.account
        ))
        XCTAssertTrue(scoped.orderedAccounts.isEmpty)
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
        let unlocked = await vault.unlock(reason: "Approve")
        let access = try XCTUnwrap(unlocked)
        let executionLeaseValue = await access.takeExecutionLease()
        let executionLease = try XCTUnwrap(executionLeaseValue)
        let reusedLease = await access.takeExecutionLease()
        XCTAssertNil(reusedLease)

        XCTAssertThrowsError(try vault.acquireCoordinationLease(
            timeoutNanoseconds: 1_000_000
        ))
        XCTAssertNotNil(vault.catalogAccess())

        executionLease.release()
        try vault.markUnavailable()
        XCTAssertNil(vault.catalogAccess())
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
        let firstAccess = await vault.unlock(reason: "First approval")
        let secondAccess = await vault.unlock(reason: "Second approval")
        let firstLeaseValue = await firstAccess?.takeExecutionLease()
        let firstLease = try XCTUnwrap(firstLeaseValue)
        defer { firstLease.release() }
        let releaseTask = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(50))
            firstLease.release()
        }
        defer { releaseTask.cancel() }

        let secondLease = await secondAccess?.takeExecutionLease()

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
            let access = RequestScopedWalletAccess(
                DerivationRaceWalletAccess(account: account) {},
                acquireExecutionLease: {
                    await withCheckedContinuation {
                        continuation = $0
                        started.fulfill()
                    }
                }
            )
            let acquisition = Task { await access.takeExecutionLease() }
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
        let keys = MemoryApprovalKeyStore()
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 8, count: 32) }
        )
        try vault.publish(
            source: fixture().source,
            integrityKey: integrityKey
        )

        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        let encodedCatalog = try XCTUnwrap(envelope["catalog"] as? String)
        var catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(Data(base64Encoded: encodedCatalog))
            ) as? [String: Any]
        )
        var accounts = try XCTUnwrap(catalog["accounts"] as? [[String: Any]])
        accounts[0]["normalizedAddress"] =
            "0x0000000000000000000000000000000000000001"
        catalog["accounts"] = accounts
        let changedCatalog = try JSONSerialization.data(
            withJSONObject: catalog,
            options: [.sortedKeys]
        )
        envelope["catalog"] = changedCatalog.base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            .write(to: url, options: .atomic)

        XCTAssertNotNil(vault.catalogAccess())
        let unlocked = await vault.unlock(reason: "Approve")
        XCTAssertNil(unlocked)
    }

    func testCatalogRejectsDuplicateDescriptor() throws {
        let descriptor = try XCTUnwrap(fixture().source.catalog.accounts.first)
        XCTAssertFalse(WalletAccountCatalog(
            accounts: [descriptor, descriptor]
        ).isValid)
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

        let catalog = try XCTUnwrap(vault.catalogAccess())
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

        let unlockedValue = await vault.unlock(reason: "Approve")
        let unlocked = try XCTUnwrap(unlockedValue)
        XCTAssertEqual(unlocked.catalogIdentity, catalog.catalogIdentity)
        XCTAssertEqual(unlocked.orderedAccounts, fixture.accounts)
        for account in fixture.accounts {
            XCTAssertNotNil(unlocked.privateKey(
                walletID: account.walletId,
                account: account.account
            ))
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
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let reordered = WalletAccountCatalog(
            accounts: Array(fixture.source.catalog.accounts.reversed())
        )
        XCTAssertTrue(reordered.isValid)
        envelope["catalog"] = try SourceWalletAccess.encodeCatalog(reordered)
            .base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            .write(to: url, options: .atomic)

        XCTAssertNotNil(vault.catalogAccess())
        let unlocked = await vault.unlock(reason: "Approve")
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
            XCTAssertNil(UnlockedWalletAccess(
                catalog: source.catalog,
                generation: UUID(),
                catalogData: try SourceWalletAccess.encodeCatalog(source.catalog),
                password: source.password,
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

        XCTAssertNil(reader.catalogAccess())
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

        XCTAssertNil(vault.catalogAccess())
    }

    func testKeychainQueriesUseProtectedApprovalGroupAndExactContext() {
        let generation = UUID()
        let context = LAContext()
        let query = SafariApprovalKeychainStore.loadQuery(
            generation: generation,
            context: context
        )

        XCTAssertEqual(
            query[kSecAttrAccessGroup as String] as? String,
            "8DXC3N7E7P.org.lil.wallet.safari-approval"
        )
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(
            query[kSecAttrAccount as String] as? String,
            generation.uuidString.lowercased()
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

    func testKeyAvailabilityMapsProductionStatusesWithoutAuthentication() {
        let generation = UUID()
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
                        generation.uuidString.lowercased()
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

            XCTAssertEqual(store.availability(generation: generation), expected)
            XCTAssertEqual(queryCount, 1)
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

        let first = try XCTUnwrap(vault.catalogAccess())
        let envelope = try Data(contentsOf: url)
        let metadata = try XCTUnwrap(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ))
        let events = keychain.events
        XCTAssertEqual(keychain.keys.count, 1)
        XCTAssertEqual(events.filter { $0 == "add" }.count, 1)
        XCTAssertNil(first.privateKey(
            walletID: "wallet",
            account: try fixture().account
        ))

        for _ in 0..<3 {
            host.reconcile()
            reconciliationQueue.sync {}
            XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, first.catalogIdentity)
        }

        XCTAssertEqual(try Data(contentsOf: url), envelope)
        XCTAssertEqual(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ), metadata)
        XCTAssertEqual(keychain.events, events)
        XCTAssertEqual(keychain.protectedKeyReads, 0)
        XCTAssertGreaterThan(keychain.availabilityReads, 0)

        let unlockedValue = await vault.unlock(reason: "Approve")
        let unlocked = try XCTUnwrap(unlockedValue)
        XCTAssertNotNil(unlocked.privateKey(walletID: "wallet", account: try fixture().account))
        let leaseValue = await unlocked.takeExecutionLease()
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
        let first = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        let envelope = try Data(contentsOf: url)
        let metadata = try XCTUnwrap(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ))
        let events = keychain.events
        keychain.availabilityStatus = errSecMissingEntitlement

        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertNil(vault.catalogAccess())
        XCTAssertEqual(try Data(contentsOf: url), envelope)
        XCTAssertEqual(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ), metadata)
        XCTAssertEqual(keychain.events, events)
        XCTAssertEqual(keychain.keys.count, 1)

        keychain.availabilityStatus = errSecInteractionNotAllowed
        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, first)
        XCTAssertEqual(keychain.events, events)
    }

    func testHostRepairsPublicationWhenGenerationKeyIsActuallyMissing() throws {
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
        let first = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        keychain.keys.removeAll()
        XCTAssertNil(vault.catalogAccess())

        host.reconcile()
        reconciliationQueue.sync {}

        let repaired = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertNotEqual(repaired.generation, first.generation)
        XCTAssertEqual(repaired.catalogData, first.catalogData)
        XCTAssertEqual(keychain.keys.count, 1)
        XCTAssertEqual(keychain.events.filter { $0 == "add" }.count, 2)
        XCTAssertEqual(keychain.protectedKeyReads, 0)
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
        let oldGeneration = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity.generation)
        try reformatStoredKey(in: &source)
        keychain.availabilityStatus = errSecMissingEntitlement

        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertNil(vault.catalogAccess())
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertNil(keychain.keys[oldGeneration.uuidString.lowercased()])
        XCTAssertNil(defaults.data(forKey: "SafariApprovalVault.hostPublicationMetadata.v1"))

        keychain.availabilityStatus = errSecInteractionNotAllowed
        host.reconcile()
        reconciliationQueue.sync {}

        let repaired = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
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
        XCTAssertNotNil(vault.catalogAccess())
        keychain.events.removeAll()
        keychain.deleteStatus = errSecIO

        XCTAssertThrowsError(try vault.publish(
            source: source,
            integrityKey: integrityKey
        )) { error in
            XCTAssertEqual(error as? SafariApprovalVault.Error, .keychainFailure(errSecIO))
        }

        XCTAssertEqual(keychain.events, ["tombstone", "delete"])
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertNil(vault.catalogAccess())
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
            let catalog = try XCTUnwrap(vault.catalogAccess())
            XCTAssertNil(catalog.privateKey(walletID: "wallet", account: fixture.account))

            let result = await vault.unlockResult(reason: "Approve")

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
        let original = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertEqual(events, ["begin", "source", "end"])
        host.start(backgroundTask: { _ in
            replacementBegins += 1
            return {}
        })
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertEqual(events, ["begin", "source", "end", "begin", "source", "end"])
        XCTAssertEqual(replacementBegins, 0)
        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, original)
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
            XCTAssertNotNil(vault.catalogAccess())
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
            XCTAssertEqual(vault.catalogAccess()?.catalogIdentity.generation, publication.generation)
            XCTAssertEqual(defaults.data(forKey: "SafariApprovalVault.hostPublicationMetadata.v1"), newerMetadata)

            host.reconcile()
            reconciliationQueue.sync {}
            XCTAssertEqual(sourceReads, 2)
            XCTAssertEqual(ends, 2)
            XCTAssertEqual(vault.catalogAccess()?.catalogIdentity.catalogData,
                           try SourceWalletAccess.encodeCatalog(replacement.catalog))
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
                XCTAssertThrowsError(try WalletSnapshotValidation.ownsStoredAccounts(
                    wallet,
                    password: source.password,
                    checkCancellation: {
                        checks += 1
                        if checks == cancelAt { expire?() }
                        try activity.checkCancellation()
                    }
                )) { XCTAssertTrue($0 is CancellationError) }
                XCTAssertEqual(checks, cancelAt)
            }
        }

        var checks = 0
        var visitedWallets = 0
        XCTAssertThrowsError(try wallets.allSatisfy { wallet in
            visitedWallets += 1
            return try WalletSnapshotValidation.ownsStoredAccounts(
                wallet,
                password: source.password,
                checkCancellation: {
                    checks += 1
                    if checks == 4 { throw CancellationError() }
                }
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
                    firstIdentity = vault.catalogAccess()?.catalogIdentity
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
        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, try XCTUnwrap(firstIdentity))
        host.start(backgroundTask: { _ in {} })
        reconciliationQueue.sync {}
        XCTAssertEqual(sourceReads, 2)
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
        XCTAssertNil(vault.catalogAccess())

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
        XCTAssertNotNil(vault.catalogAccess())
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
        let original = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        let accessValue = await vault.unlock(reason: "Approve")
        let access = try XCTUnwrap(accessValue)
        let leaseValue = await access.takeExecutionLease()
        let lease = try XCTUnwrap(leaseValue)
        defer { lease.release() }

        let startedAt = ContinuousClock.now
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
        XCTAssertEqual(sourceReads, 1)
        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, original)

        await Task { @MainActor in lease.release() }.value
        await fulfillment(of: [reconciled], timeout: 2)
        reconciliationQueue.sync {}
        XCTAssertEqual(sourceReads, 2)
        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, original)
    }

    @MainActor
    func testSuccessfulHostWorkCancelsDeferredReconciliation() throws {
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
                try host.performSourceMutation {
                    XCTAssertNil(vault.catalogAccess())
                }
            } else {
                host.reconcile()
            }
            reconciliationQueue.sync {}
            XCTAssertTrue(retry.isCancelled)
            XCTAssertEqual(sourceReads, 2)
            reconciliationQueue.sync { retry.perform() }
            XCTAssertEqual(sourceReads, 2)
            XCTAssertNotNil(vault.catalogAccess())
        }
    }

    @MainActor
    func testSourceMutationsRevokeImmediatelyAndCoalesceBackgroundPublication()
        throws {
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
        let first = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, first)

        reconciliationQueue.suspend()
        do {
            defer { reconciliationQueue.resume() }
            for index in 0..<2 {
                let result = try host.performSourceMutation {
                    XCTAssertNil(vault.catalogAccess())
                    XCTAssertTrue(keys.keys.isEmpty)
                    source = index == 0 ? nil : replacement
                    return "saved"
                }
                XCTAssertEqual(result, "saved")
            }
            XCTAssertNil(vault.catalogAccess())
            XCTAssertTrue(keys.keys.isEmpty)
            XCTAssertEqual(sourceReads, 2)
        }
        reconciliationQueue.sync {}
        XCTAssertEqual(sourceReads, 3)
        let second = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertNotEqual(second.generation, first.generation)
        XCTAssertEqual(second.catalogData, try SourceWalletAccess.encodeCatalog(replacement.catalog))
    }

    func testHostAbortsSourceMutationWhenUnavailableTombstoneWriteFails()
        throws {
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
        let initial = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        rejectTombstone = true
        var didMutate = false

        XCTAssertThrowsError(try host.performSourceMutation {
            didMutate = true
        })

        XCTAssertFalse(didMutate)
        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, initial)
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
            vault.catalogAccess()?.catalogIdentity.generation
        )
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        var tag = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(envelope["tag"] as? String))
        )
        tag[0] ^= 0xff
        envelope["tag"] = tag.base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            .write(to: url, options: .atomic)

        host.reconcile()
        reconciliationQueue.sync {}

        let repaired = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
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
        let first = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)

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

        let repaired = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertNotEqual(repaired.generation, first.generation)
        XCTAssertEqual(repaired.catalogData, first.catalogData)
    }

    func testPublicationAndSelectedSignerRejectWrongPassword() throws {
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

        let access = try unlockedAccess(source: source)
        defer { access.invalidate() }
        XCTAssertNil(access.privateKey(
            walletID: "wallet",
            account: try XCTUnwrap(access.orderedAccounts.first).account
        ))
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
        let first = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
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

        let repaired = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
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
        let initial = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        let envelope = try Data(contentsOf: url)
        let unlocked = await vault.unlock(reason: "Already approved")
        let access = try XCTUnwrap(unlocked)
        rejectSynchronization = true

        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, initial)
        XCTAssertEqual(try Data(contentsOf: url), envelope)
        XCTAssertNotNil(keys.keys[try XCTUnwrap(initial.generation)])
        XCTAssertNotNil(access.privateKey(walletID: "wallet", account: fixture.account))
    }

    func testFailedSourceMutationReconcilesAndPreservesErrorWhenMetadataSynchronizationFails()
        throws {
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
        let first = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertEqual(stores, 1)
        rejectMetadataUpdates = true
        var mutations = 0

        XCTAssertThrowsError(try host.performSourceMutation {
            mutations += 1
            XCTAssertEqual(stores, 1)
            XCTAssertNil(vault.catalogAccess())
            throw CocoaError(.fileWriteNoPermission)
        }) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
        }

        XCTAssertEqual(mutations, 1)
        XCTAssertEqual(source.password, try fixture().source.password)
        XCTAssertEqual(
            source.wallets.map(\.storedKeyJSON),
            try fixture().source.wallets.map(\.storedKeyJSON)
        )

        reconciliationQueue.sync {}

        let recovered = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertEqual(stores, 2)
        XCTAssertNotEqual(recovered.generation, first.generation)
        XCTAssertEqual(recovered.catalogData, first.catalogData)
    }

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
        let originalIdentity = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        let unlocked = await vault.unlock(reason: "Before metadata failure")
        let previousAccess = try XCTUnwrap(unlocked)
        XCTAssertNotNil(previousAccess.privateKey(
            walletID: "wallet",
            account: original.account
        ))
        rejectSynchronization = true
        var mutations = 0

        let result = try host.performSourceMutation {
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
        let current = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        let envelope = try Data(contentsOf: url)
        let metadata = try XCTUnwrap(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ))
        XCTAssertNotEqual(current.generation, originalIdentity.generation)
        XCTAssertNotEqual(current.catalogData, originalIdentity.catalogData)
        XCTAssertTrue(previousAccess.orderedAccounts.isEmpty)
        XCTAssertNil(previousAccess.privateKey(
            walletID: "wallet",
            account: original.account
        ))
        let previousLease = await previousAccess.takeExecutionLease()
        XCTAssertNil(previousLease)
        let replacementUnlock = await vault.unlock(reason: "During metadata failure")
        let replacementAccess = try XCTUnwrap(replacementUnlock)
        XCTAssertNotNil(replacementAccess.privateKey(
            walletID: "mnemonic-wallet",
            account: replacement.account
        ))

        for _ in 0..<2 {
            let previousFailures = synchronizationFailures
            host.reconcile()
            reconciliationQueue.sync {}
            XCTAssertGreaterThan(synchronizationFailures, previousFailures)
            XCTAssertEqual(mutations, 1)
            XCTAssertEqual(stores, 2)
            XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, current)
            XCTAssertEqual(try Data(contentsOf: url), envelope)
            XCTAssertEqual(defaults.data(
                forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
            ), metadata)
            XCTAssertNotNil(replacementAccess.privateKey(
                walletID: "mnemonic-wallet",
                account: replacement.account
            ))
        }

        rejectSynchronization = false
        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertEqual(mutations, 1)
        XCTAssertEqual(stores, 2)
        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, current)
        XCTAssertEqual(try Data(contentsOf: url), envelope)
        let recoveredUnlock = await vault.unlock(reason: "After metadata recovery")
        let recoveredAccess = try XCTUnwrap(recoveredUnlock)
        XCTAssertNotNil(recoveredAccess.privateKey(
            walletID: "mnemonic-wallet",
            account: replacement.account
        ))
        XCTAssertNil(keys.keys[try XCTUnwrap(originalIdentity.generation)])
        XCTAssertTrue(previousAccess.orderedAccounts.isEmpty)
        let replayedLease = await previousAccess.takeExecutionLease()
        XCTAssertNil(replayedLease)
    }

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
        let first = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        let originalUnlock = await vault.unlock(reason: "Before mutation")
        let previousAccess = try XCTUnwrap(originalUnlock)
        failNextSynchronization = true
        var mutations = 0

        let result = try host.performSourceMutation {
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
        let current = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertNotEqual(current.generation, first.generation)
        XCTAssertNotEqual(current.catalogData, first.catalogData)
        XCTAssertNotNil(defaults.data(forKey: "SafariApprovalVault.hostPublicationMetadata.v1"))
        XCTAssertNil(keys.keys[try XCTUnwrap(first.generation)])
        XCTAssertTrue(previousAccess.orderedAccounts.isEmpty)
        let previousLease = await previousAccess.takeExecutionLease()
        XCTAssertNil(previousLease)
        let replacementUnlock = await vault.unlock(reason: "After mutation")
        let access = try XCTUnwrap(replacementUnlock)
        XCTAssertNotNil(access.privateKey(walletID: "mnemonic-wallet", account: replacement.account))
    }

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
        let unlocked = await vault.unlock(reason: "Before mutation")
        let priorAccess = try XCTUnwrap(unlocked)
        let attemptsBeforeRevocation = synchronizationAttempts
        reconciliationQueue.suspend()
        defer {
            reconciliationQueue.resume()
            reconciliationQueue.sync {}
        }

        keys.removeError = SafariApprovalVault.Error.keychainFailure(errSecIO)
        XCTAssertThrowsError(try host.performSourceMutation {
            XCTFail("Source mutation must not run if key revocation fails")
            source = nil
        })
        XCTAssertNotNil(source)
        XCTAssertEqual(synchronizationAttempts, attemptsBeforeRevocation)

        keys.removeError = nil
        XCTAssertThrowsError(try host.performSourceMutation {
            XCTAssertTrue(keys.keys.isEmpty)
            source = nil
            throw SafariApprovalVault.Error.unavailable
        })
        XCTAssertNil(source)
        try cachedEnvelope.write(to: url, options: .atomic)

        XCTAssertNil(vault.catalogAccess())
        let replayedAccess = await vault.unlock(reason: "After mutation")
        XCTAssertNil(replayedAccess)
        XCTAssertTrue(priorAccess.orderedAccounts.isEmpty)
        let priorLease = await priorAccess.takeExecutionLease()
        XCTAssertNil(priorLease)
    }

    func testPublicationRevokesOldKeysBeforeSourceMutation()
        throws {
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

        try host.performSourceMutation {
            events.append("source")
            XCTAssertNil(vault.catalogAccess())
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
        XCTAssertNotNil(vault.catalogAccess())
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

        XCTAssertNil(vault.catalogAccess())
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertTrue(keys.keys.isEmpty)
        keys.storeError = nil
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertNotNil(vault.catalogAccess())
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

        XCTAssertNil(vault.catalogAccess())
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertTrue(keys.keys.isEmpty)
        try cachedEnvelope.write(to: url, options: .atomic)
        XCTAssertNil(vault.catalogAccess())
        let replayedAccess = await vault.unlock(reason: "After publication failure")
        XCTAssertNil(replayedAccess)
        rejectEnvelope = false
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertNotNil(vault.catalogAccess())
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

        XCTAssertNil(vault.catalogAccess())
        XCTAssertTrue(keys.keys.isEmpty)
        rejectTombstone = false
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertNotNil(vault.catalogAccess())
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
        let initial = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        let envelope = try Data(contentsOf: url)
        let metadata = try XCTUnwrap(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ))
        let unlocked = await vault.unlock(reason: "During metadata failure")
        let access = try XCTUnwrap(unlocked)
        XCTAssertNotNil(access.privateKey(walletID: "wallet", account: fixture.account))
        XCTAssertNil(synchronizedMetadata)
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertEqual(stores, 1)
        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, initial)
        XCTAssertEqual(try Data(contentsOf: url), envelope)
        XCTAssertNotNil(keys.keys[try XCTUnwrap(initial.generation)])

        rejectSynchronization = false
        host.reconcile()
        reconciliationQueue.sync {}

        XCTAssertEqual(synchronizedMetadata, metadata)
        XCTAssertEqual(stores, 1)
        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, initial)
        XCTAssertEqual(try Data(contentsOf: url), envelope)
        XCTAssertNotNil(access.privateKey(walletID: "wallet", account: fixture.account))
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

        XCTAssertNil(vault.catalogAccess())
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertEqual(keys.keys.count, 1)
        keys.removeError = nil
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertNotNil(vault.catalogAccess())
        XCTAssertEqual(keys.keys.count, 1)
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
        let first = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)

        integrityKeys.key = nil
        host.reconcile()
        reconciliationQueue.sync {}
        let afterMissing = try XCTUnwrap(
            vault.catalogAccess()?.catalogIdentity
        )
        XCTAssertNotEqual(afterMissing.generation, first.generation)

        integrityKeys.key = Data(repeating: 0xd0, count: 32)
        host.reconcile()
        reconciliationQueue.sync {}
        let afterRotation = try XCTUnwrap(
            vault.catalogAccess()?.catalogIdentity
        )
        XCTAssertNotEqual(
            afterRotation.generation,
            afterMissing.generation
        )

        integrityKeys.error = SafariApprovalVault.Error.keychainFailure(errSecIO)
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertNil(vault.catalogAccess())
        XCTAssertEqual(try Data(contentsOf: url), Data())

        integrityKeys.error = nil
        host.reconcile()
        reconciliationQueue.sync {}
        XCTAssertNotNil(vault.catalogAccess())
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
            XCTAssertTrue(keys.isEmpty)
            keys[account] = data
            return errSecSuccess
        },
        copyMatching: { [unowned self] query, result in
            let query = query as NSDictionary
            guard let account = query[kSecAttrAccount] as? String,
                  let context = query[kSecUseAuthenticationContext] as? LAContext else {
                XCTFail("Approval keys must be queried by generation with an explicit context")
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
            return availabilityStatus
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
    var keys = [UUID: Data]()
    var loadedContext: LAContext?
    var onLoad: (() -> Void)?
    var onStore: ((UUID) -> Void)?
    var onRemove: (() -> Void)?
    var storeError: Swift.Error?
    var removeError: Swift.Error?

    func store(_ key: Data, generation: UUID) throws {
        onStore?(generation)
        if let storeError { throw storeError }
        keys[generation] = key
    }

    func load(generation: UUID, context: LAContext) throws -> Data {
        loadedContext = context
        guard let key = keys[generation] else {
            throw SafariApprovalVault.Error.invalidKey
        }
        onLoad?()
        return key
    }

    func availability(generation: UUID) -> SafariApprovalKeyAvailability {
        keys[generation] == nil ? .missing : .present
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

private final class DerivationRaceWalletAccess: WalletAccess {
    let catalogIdentity = WalletCatalogIdentity(
        generation: UUID(),
        catalogData: Data("catalog".utf8)
    )
    let orderedAccounts: [SpecificWalletAccount]
    private let didDerive: () -> Void

    init(account: WalletAccount, didDerive: @escaping () -> Void) {
        orderedAccounts = [SpecificWalletAccount(
            walletId: "wallet",
            account: account
        )]
        self.didDerive = didDerive
    }

    func privateKey(
        walletID: String,
        account: WalletAccount
    ) -> WalletPrivateKey? {
        didDerive()
        return WalletPrivateKey(data: Data(repeating: 1, count: 32))
    }
}
#endif
