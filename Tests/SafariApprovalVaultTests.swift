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
            sourceRevision: 7,
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
            "sourceRevision",
            "tag",
            "version",
        ])
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertEqual(envelope["sourceRevision"] as? Int, 7)
        let catalogJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: SourceWalletAccess.encodeCatalog(fixture.source.catalog)
            ) as? [String: Any]
        )
        let descriptors = try XCTUnwrap(
            catalogJSON["accounts"] as? [[String: Any]]
        )
        XCTAssertEqual(Set(try XCTUnwrap(descriptors.first).keys), [
            "accountOrder",
            "coin",
            "derivationPath",
            "normalizedAddress",
            "walletID",
            "walletOrder",
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
            sourceRevision: 11,
            integrityKey: integrityKey
        )

        let data = try Data(contentsOf: url)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["sourceRevision"] = 12
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url, options: .atomic)

        let unlocked = await vault.unlock(reason: "Approve")
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
            sourceRevision: 1,
            integrityKey: integrityKey
        )

        let unlockedValue = await vault.unlock(reason: "Approve")
        let unlocked = try XCTUnwrap(unlockedValue)

        XCTAssertNotNil(unlocked.privateKey(
            walletID: "mnemonic-wallet",
            account: fixture.account
        ))
    }

    func testUnlockRejectsMnemonicAccountNotOwnedByDecryptedSeed() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: MemoryApprovalKeyStore(),
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 20, count: 32) }
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
        try vault.publish(
            source: source,
            sourceRevision: 1,
            integrityKey: integrityKey
        )

        let unlocked = await vault.unlock(reason: "Approve")
        XCTAssertNil(unlocked)
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
            sourceRevision: 3,
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
            sourceRevision: 20,
            integrityKey: integrityKey
        )
        keys.onLoad = {
            keys.onLoad = nil
            _ = try? vault.publish(
                source: source,
                sourceRevision: 21,
                integrityKey: self.integrityKey
            )
        }

        let result = await vault.unlockResult(reason: "Approve")

        guard case .unavailable = result else {
            return XCTFail("A rotated envelope must invalidate the unlock")
        }
        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity.sourceRevision, 21)
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
            sourceRevision: 30,
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
            sourceRevision: 1,
            integrityKey: integrityKey
        )
        let unlocked = await vault.unlock(reason: "Approve")
        let access = try XCTUnwrap(unlocked)
        let executionLease = try XCTUnwrap(access.takeExecutionLease())
        XCTAssertNil(access.takeExecutionLease())

        XCTAssertThrowsError(try vault.acquireCoordinationLease(
            timeoutNanoseconds: 1_000_000
        ))
        XCTAssertNotNil(vault.catalogAccess())

        executionLease.release()
        try vault.markUnavailable()
        XCTAssertNil(vault.catalogAccess())
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
            sourceRevision: 13,
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

    func testCatalogRejectsDuplicateLogicalDescriptorWithDifferentOrder() throws {
        let descriptor = try XCTUnwrap(fixture().source.catalog.accounts.first)
        let duplicate = WalletAccountDescriptor(
            walletID: descriptor.walletID,
            coin: descriptor.coin,
            normalizedAddress: descriptor.normalizedAddress,
            derivationPath: descriptor.derivationPath,
            walletOrder: descriptor.walletOrder,
            accountOrder: descriptor.accountOrder + 1
        )
        XCTAssertFalse(WalletAccountCatalog(
            accounts: [descriptor, duplicate]
        ).isValid)
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
            sourceRevision: 1,
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
            sourceRevision: 1,
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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            sourceSnapshot: { source }
        )

        host.start()

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
        let lease = try XCTUnwrap(unlocked.takeExecutionLease())
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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            sourceSnapshot: { source }
        )
        host.start()
        let first = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        let envelope = try Data(contentsOf: url)
        let metadata = try XCTUnwrap(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ))
        let events = keychain.events
        keychain.availabilityStatus = errSecMissingEntitlement

        host.reconcile()

        XCTAssertNil(vault.catalogAccess())
        XCTAssertEqual(try Data(contentsOf: url), envelope)
        XCTAssertEqual(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ), metadata)
        XCTAssertEqual(keychain.events, events)
        XCTAssertEqual(keychain.keys.count, 1)

        keychain.availabilityStatus = errSecInteractionNotAllowed
        host.reconcile()

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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            sourceSnapshot: { source }
        )
        host.start()
        let first = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        keychain.keys.removeAll()
        XCTAssertNil(vault.catalogAccess())

        host.reconcile()

        let repaired = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertNotEqual(repaired.generation, first.generation)
        XCTAssertEqual(repaired.sourceRevision, first.sourceRevision)
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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            sourceSnapshot: { source }
        )
        host.start()
        let oldGeneration = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity.generation)
        source.password.append(0x31)
        keychain.availabilityStatus = errSecMissingEntitlement

        host.reconcile()

        XCTAssertNil(vault.catalogAccess())
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertNil(keychain.keys[oldGeneration.uuidString.lowercased()])
        XCTAssertNil(defaults.data(forKey: "SafariApprovalVault.hostPublicationMetadata.v1"))

        keychain.availabilityStatus = errSecInteractionNotAllowed
        host.reconcile()

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

        try vault.publish(source: source, sourceRevision: 1, integrityKey: integrityKey)

        XCTAssertEqual(keychain.events, ["tombstone", "delete", "add", "envelope"])
        XCTAssertEqual(keychain.keys.count, 1)
        XCTAssertNotNil(vault.catalogAccess())
        keychain.events.removeAll()
        keychain.deleteStatus = errSecIO

        XCTAssertThrowsError(try vault.publish(
            source: source,
            sourceRevision: 2,
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
                sourceRevision: 1,
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

    func testHostKeepsGenerationStableUntilSynchronousMutationBoundary()
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
        let source = try fixture().source
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            sourceSnapshot: { source }
        )

        host.start()
        let first = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        host.reconcile()
        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, first)

        try host.performSourceMutation {
            XCTAssertNil(vault.catalogAccess())
            XCTAssertTrue(keys.keys.isEmpty)
        }
        let second = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertNotEqual(second.generation, first.generation)
        XCTAssertEqual(second.sourceRevision, first.sourceRevision.map { $0 + 1 })
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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            sourceSnapshot: { source }
        )
        host.start()
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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            sourceSnapshot: { source }
        )
        host.start()
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

        let repaired = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertNotEqual(repaired.generation, firstGeneration)
        XCTAssertEqual(repaired.sourceRevision, 1)
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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            sourceSnapshot: { source }
        )
        host.start()
        let first = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)

        source.password = Data("changed-password".utf8)
        host.reconcile()

        let repaired = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertNotEqual(repaired.generation, first.generation)
        XCTAssertEqual(repaired.sourceRevision, first.sourceRevision)
        XCTAssertEqual(repaired.catalogData, first.catalogData)
    }

    func testUnlockRejectsPasswordThatCannotDecryptStoredWallets() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: MemoryApprovalKeyStore(),
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 18, count: 32) }
        )
        var source = try fixture().source
        source.password = Data("wrong-password".utf8)
        try vault.publish(
            source: source,
            sourceRevision: 1,
            integrityKey: integrityKey
        )

        XCTAssertNotNil(vault.catalogAccess())
        let unlocked = await vault.unlock(reason: "Approve")
        XCTAssertNil(unlocked)
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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            sourceSnapshot: { source }
        )
        host.start()
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

        let repaired = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertNotEqual(repaired.generation, first.generation)
        XCTAssertEqual(repaired.sourceRevision, first.sourceRevision)
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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            synchronizeDefaults: { value in
                rejectSynchronization ? false : value.synchronize()
            },
            sourceSnapshot: { fixture.source }
        )
        host.start()
        let initial = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        let envelope = try Data(contentsOf: url)
        let unlocked = await vault.unlock(reason: "Already approved")
        let access = try XCTUnwrap(unlocked)
        rejectSynchronization = true

        host.reconcile()

        XCTAssertEqual(vault.catalogAccess()?.catalogIdentity, initial)
        XCTAssertEqual(try Data(contentsOf: url), envelope)
        XCTAssertNotNil(keys.keys[try XCTUnwrap(initial.generation)])
        XCTAssertNotNil(access.privateKey(walletID: "wallet", account: fixture.account))
    }

    func testFailedSourceMutationPreservesSourceErrorWhenMetadataSynchronizationFails()
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
        var rejectRevisionUpdates = false
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            synchronizeDefaults: { value in
                if rejectRevisionUpdates && value.integer(
                    forKey: "SafariApprovalVault.hostSourceRevision.v1"
                ) > 1 {
                    return false
                }
                return value.synchronize()
            },
            sourceSnapshot: { source }
        )
        host.start()
        let first = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertEqual(stores, 1)
        rejectRevisionUpdates = true
        var mutations = 0

        XCTAssertThrowsError(try host.performSourceMutation {
            mutations += 1
            throw CocoaError(.fileWriteNoPermission)
        }) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
        }

        XCTAssertEqual(mutations, 1)
        XCTAssertEqual(stores, 1)
        XCTAssertNil(vault.catalogAccess())
        XCTAssertEqual(source.password, try fixture().source.password)
        XCTAssertEqual(
            source.wallets.map(\.storedKeyJSON),
            try fixture().source.wallets.map(\.storedKeyJSON)
        )

        rejectRevisionUpdates = false
        host.reconcile()

        let recovered = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertEqual(stores, 2)
        XCTAssertNotEqual(recovered.generation, first.generation)
        XCTAssertEqual(recovered.sourceRevision, first.sourceRevision.map { $0 + 1 })
    }

    func testSourceMutationSurvivesFailedInitialRevisionSynchronization()
        async throws {
        try await assertSourceMutationRecoversAfterRevisionSynchronizationFailure(
            initializingRevision: true
        )
    }

    func testSourceMutationSurvivesFailedRevisionIncrementSynchronization()
        async throws {
        try await assertSourceMutationRecoversAfterRevisionSynchronizationFailure(
            initializingRevision: false
        )
    }

    private func assertSourceMutationRecoversAfterRevisionSynchronizationFailure(
        initializingRevision: Bool
    ) async throws {
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
        var sourceLoads = 0
        var rejectSynchronization = false
        var synchronizationFailures = 0
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            synchronizeDefaults: { value in
                if rejectSynchronization && (initializingRevision || value.integer(
                    forKey: "SafariApprovalVault.hostSourceRevision.v1"
                ) > 1) {
                    synchronizationFailures += 1
                    return false
                }
                return value.synchronize()
            },
            sourceSnapshot: {
                sourceLoads += 1
                return source
            }
        )
        if initializingRevision {
            try vault.publish(
                source: source,
                sourceRevision: 1,
                integrityKey: integrityKey
            )
        } else {
            host.start()
        }
        let originalIdentity = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        let unlocked = await vault.unlock(reason: "Before metadata failure")
        let previousAccess = try XCTUnwrap(unlocked)
        XCTAssertNotNil(previousAccess.privateKey(
            walletID: "wallet",
            account: original.account
        ))
        let initialSourceLoads = sourceLoads
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
        XCTAssertEqual(stores, 1)
        XCTAssertEqual(sourceLoads, initialSourceLoads)
        XCTAssertGreaterThan(synchronizationFailures, 0)
        XCTAssertNil(vault.catalogAccess())
        XCTAssertTrue(keys.keys.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertNil(defaults.data(
            forKey: "SafariApprovalVault.hostPublicationMetadata.v1"
        ))
        XCTAssertTrue(previousAccess.orderedAccounts.isEmpty)
        XCTAssertNil(previousAccess.privateKey(
            walletID: "wallet",
            account: original.account
        ))
        XCTAssertNil(previousAccess.takeExecutionLease())

        for _ in 0..<2 {
            let previousFailures = synchronizationFailures
            host.reconcile()
            XCTAssertGreaterThan(synchronizationFailures, previousFailures)
            XCTAssertEqual(mutations, 1)
            XCTAssertEqual(stores, 1)
            XCTAssertNil(vault.catalogAccess())
            XCTAssertTrue(keys.keys.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), Data())
        }

        rejectSynchronization = false
        host.reconcile()

        let recovered = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)
        XCTAssertEqual(mutations, 1)
        XCTAssertEqual(stores, 2)
        XCTAssertNotEqual(recovered.generation, originalIdentity.generation)
        XCTAssertNotEqual(recovered.catalogData, originalIdentity.catalogData)
        XCTAssertEqual(recovered.sourceRevision, initializingRevision ? 1 : 2)
        let recoveredUnlock = await vault.unlock(reason: "After metadata recovery")
        let recoveredAccess = try XCTUnwrap(recoveredUnlock)
        XCTAssertNotNil(recoveredAccess.privateKey(
            walletID: "mnemonic-wallet",
            account: replacement.account
        ))
        XCTAssertNil(keys.keys[try XCTUnwrap(originalIdentity.generation)])
        XCTAssertTrue(previousAccess.orderedAccounts.isEmpty)
        XCTAssertNil(previousAccess.takeExecutionLease())
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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(key: integrityKey),
            synchronizeDefaults: { value in
                synchronizationAttempts += 1
                return value.synchronize()
            },
            sourceSnapshot: { source }
        )
        host.start()
        let cachedEnvelope = try Data(contentsOf: url)
        let unlocked = await vault.unlock(reason: "Before mutation")
        let priorAccess = try XCTUnwrap(unlocked)
        let attemptsBeforeRevocation = synchronizationAttempts

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
        XCTAssertNil(priorAccess.takeExecutionLease())
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
            sourceSnapshot: { source }
        )
        host.start()
        events.removeAll()

        try host.performSourceMutation {
            events.append("source")
            XCTAssertNil(vault.catalogAccess())
        }

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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            sourceSnapshot: { source }
        )
        host.start()
        source.password.append(0x21)
        keys.storeError = SafariApprovalVault.Error.keychainFailure(errSecIO)

        host.reconcile()

        XCTAssertNil(vault.catalogAccess())
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertTrue(keys.keys.isEmpty)
        keys.storeError = nil
        host.reconcile()
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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            sourceSnapshot: { source }
        )
        host.start()
        let cachedEnvelope = try Data(contentsOf: url)
        source.password.append(0x22)
        rejectEnvelope = true

        host.reconcile()

        XCTAssertNil(vault.catalogAccess())
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertTrue(keys.keys.isEmpty)
        try cachedEnvelope.write(to: url, options: .atomic)
        XCTAssertNil(vault.catalogAccess())
        let replayedAccess = await vault.unlock(reason: "After publication failure")
        XCTAssertNil(replayedAccess)
        rejectEnvelope = false
        host.reconcile()
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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            sourceSnapshot: { source }
        )
        host.start()
        XCTAssertEqual(keys.keys.count, 1)
        source.password.append(0x25)
        rejectTombstone = true

        host.reconcile()

        XCTAssertNil(vault.catalogAccess())
        XCTAssertTrue(keys.keys.isEmpty)
        rejectTombstone = false
        host.reconcile()
        XCTAssertNotNil(vault.catalogAccess())
        XCTAssertEqual(keys.keys.count, 1)
    }

    func testPublicationMetadataFailureStaysUnavailableAndRecovers() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryApprovalKeyStore()
        var rejectNextPublicationMetadata = false
        var envelopeWasWritten = false
        let vault = SafariApprovalVault(
            fileURL: url,
            keyStore: keys,
            canEvaluateAuthentication: { _, _ in true },
            authentication: { _, _, _ in true },
            randomKey: { Data(repeating: 17, count: 32) },
            atomicWrite: { data, destination in
                try data.write(to: destination, options: .atomic)
                if !data.isEmpty {
                    envelopeWasWritten = true
                }
            }
        )
        let suite = "SafariApprovalVaultHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var source = try fixture().source
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            synchronizeDefaults: { value in
                if rejectNextPublicationMetadata && envelopeWasWritten {
                    rejectNextPublicationMetadata = false
                    envelopeWasWritten = false
                    return false
                }
                return value.synchronize()
            },
            sourceSnapshot: { source }
        )
        host.start()
        envelopeWasWritten = false
        source.password.append(0x23)
        rejectNextPublicationMetadata = true

        host.reconcile()

        XCTAssertNil(vault.catalogAccess())
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertTrue(keys.keys.isEmpty)
        host.reconcile()
        XCTAssertNotNil(vault.catalogAccess())
        XCTAssertEqual(keys.keys.count, 1)
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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: MemoryApprovalIntegrityKeyStore(
                key: integrityKey
            ),
            sourceSnapshot: { source }
        )
        host.start()
        source.password.append(0x24)
        keys.removeError = SafariApprovalVault.Error.keychainFailure(errSecIO)

        host.reconcile()

        XCTAssertNil(vault.catalogAccess())
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertEqual(keys.keys.count, 1)
        keys.removeError = nil
        host.reconcile()
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
        let host = SafariApprovalVaultHost(
            vault: vault,
            defaults: defaults,
            integrityKeyStore: integrityKeys,
            sourceSnapshot: { source }
        )
        host.start()
        let first = try XCTUnwrap(vault.catalogAccess()?.catalogIdentity)

        integrityKeys.key = nil
        host.reconcile()
        let afterMissing = try XCTUnwrap(
            vault.catalogAccess()?.catalogIdentity
        )
        XCTAssertNotEqual(afterMissing.generation, first.generation)

        integrityKeys.key = Data(repeating: 0xd0, count: 32)
        host.reconcile()
        let afterRotation = try XCTUnwrap(
            vault.catalogAccess()?.catalogIdentity
        )
        XCTAssertNotEqual(
            afterRotation.generation,
            afterMissing.generation
        )

        integrityKeys.error = SafariApprovalVault.Error.keychainFailure(errSecIO)
        host.reconcile()
        XCTAssertNil(vault.catalogAccess())
        XCTAssertEqual(try Data(contentsOf: url), Data())

        integrityKeys.error = nil
        host.reconcile()
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
        sourceRevision: 1,
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
