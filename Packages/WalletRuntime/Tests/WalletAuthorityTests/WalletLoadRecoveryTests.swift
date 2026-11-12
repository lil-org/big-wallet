import Foundation
import Security
import Synchronization
import WalletDomain
import WalletRuntimeTestSupport
import XCTest
@testable import WalletAuthority

@MainActor
final class WalletLoadRecoveryTests: XCTestCase {
    func testFailurePublishesStatusWithoutPublishingOrDiscardingCachedWallets() async throws {
        let reader = makeReader()
        var publications = 0
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching),
                                    publishLocalChange: { publications += 1 })
        let states = Mutex([WalletsManager.LoadState]())
        let observer = NotificationCenter.default.addObserver(forName: .walletsLoadStateChanged, object: manager, queue: .main) { _ in
            let state = MainActor.assumeIsolated { manager.loadState }
            states.withLock { $0.append(state) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertEqual(manager.loadState, .idle)
        XCTAssertNil(manager.reviewCatalog())
        await assertWalletReload(manager)
        let original = manager.wallets
        reader.attributesStatus = errSecInteractionNotAllowed
        await assertWalletReload(manager, succeeds: false)
        await assertWalletReload(manager, succeeds: false)

        XCTAssertEqual(manager.wallets, original)
        XCTAssertTrue(manager.hasLoadedSnapshot)
        XCTAssertFalse(manager.isStoreReady)
        XCTAssertNil(manager.reviewCatalog())
        XCTAssertEqual(publications, 1)
        reader.attributesStatus = errSecSuccess
        await assertWalletReload(manager)
        XCTAssertNotNil(manager.reviewCatalog())
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(states.withLock { $0 }, [
            .loading, .ready, .failed(.unavailable),
            .loading, .failed(.unavailable), .loading, .ready,
        ])
    }

    func testConcurrentReloadsShareAReadAndOneCancelledWaiterDoesNotCancelOthers() async throws {
        let reader = makeReader()
        let entered = expectation(description: "Store read started")
        let joined = expectation(description: "Second caller joined")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reads = Mutex(0)
        let manager = WalletsManager(keychain: Keychain(copyMatching: { query, result in
            if (query as NSDictionary)[kSecReturnAttributes as String] as? Bool == true {
                let first = reads.withLock { count in count += 1; return count == 1 }
                if first { entered.fulfill(); release.wait() }
            }
            return reader.copyMatching(query, result)
        }))
        let first = Task { await manager.reloadFromStore() }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task {
            joined.fulfill()
            return await manager.reloadFromStore()
        }
        await fulfillment(of: [joined], timeout: 2)
        first.cancel()
        release.signal()
        let firstResult = await first.value
        let secondResult = await second.value

        XCTAssertFalse(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(reads.withLock { $0 }, 1)
        XCTAssertEqual(manager.loadState, .ready)
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet"])
    }

    func testCancelledRefreshPreservesSnapshotAndAnyObservedFailure() async throws {
        for readFails in [false, true] {
            let reader = makeReader()
            let entered = expectation(description: "Refresh started")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let reads = Mutex(0)
            let manager = WalletsManager(keychain: Keychain(copyMatching: { query, result in
                if (query as NSDictionary)[kSecReturnAttributes as String] as? Bool == true {
                    let blocked = reads.withLock { count in count += 1; return count == 2 }
                    if blocked { entered.fulfill(); release.wait() }
                }
                return reader.copyMatching(query, result)
            }))
            await assertWalletReload(manager)
            let refresh = Task { await manager.reloadFromStore() }
            await fulfillment(of: [entered], timeout: 2)
            reader.attributesStatus = readFails ? errSecInteractionNotAllowed : errSecSuccess
            refresh.cancel()
            release.signal()
            let cancelled = await refresh.value

            XCTAssertFalse(cancelled)
            XCTAssertEqual(manager.loadState, readFails ? .failed(.unavailable) : .ready)
            XCTAssertEqual(manager.wallets.map(\.id), ["wallet"])
            reader.attributesStatus = errSecSuccess
            reader.attributes = []
            await assertWalletReload(manager)
            XCTAssertTrue(manager.wallets.isEmpty)
            XCTAssertTrue(manager.hasLoadedSnapshot)
            XCTAssertTrue(manager.isStoreReady)
        }
    }

    func testCancellingAllSharedCallersStopsTheirReadAndANewCallerStartsAFreshRead() async throws {
        let reader = makeReader()
        let entered = expectation(description: "Shared enumeration started")
        let joined = expectation(description: "Second caller joined")
        let replacementRequested = expectation(description: "Fresh caller requested a reload")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reads = Mutex((enumerations: 0, wallets: 0))
        let manager = WalletsManager(keychain: Keychain(copyMatching: { query, result in
            let fields = query as NSDictionary
            if fields[kSecReturnAttributes as String] as? Bool == true {
                let first = reads.withLock { $0.enumerations += 1; return $0.enumerations == 1 }
                if first { entered.fulfill(); release.wait() }
            }
            if fields[kSecAttrAccount as String] as? String == "org.lil.wallet.wallet.wallet" {
                reads.withLock { $0.wallets += 1 }
            }
            return reader.copyMatching(query, result)
        }))
        let first = Task { await manager.reloadFromStore() }
        await fulfillment(of: [entered], timeout: 3)
        let second = Task {
            joined.fulfill()
            return await manager.reloadFromStore()
        }
        await fulfillment(of: [joined], timeout: 3)
        first.cancel()
        second.cancel()
        let replacement = Task {
            replacementRequested.fulfill()
            return await manager.reloadFromStore()
        }
        await fulfillment(of: [replacementRequested], timeout: 3)
        release.signal()

        let firstResult = await first.value
        let secondResult = await second.value
        let replacementResult = await replacement.value
        XCTAssertFalse(firstResult)
        XCTAssertFalse(secondResult)
        XCTAssertTrue(replacementResult)
        XCTAssertEqual(reads.withLock { $0.enumerations }, 2)
        XCTAssertEqual(reads.withLock { $0.wallets }, 1)
        XCTAssertTrue(manager.isStoreReady)
        XCTAssertNotNil(manager.reviewCatalog())
    }

    func testExternalMutationDuringEnumerationRequiresAFreshSnapshot() async throws {
        let reader = makeReader()
        let entered = expectation(description: "Old inventory is being loaded")
        let notified = expectation(description: "External mutation was observed")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let blocked = Mutex(false)
        let manager = WalletsManager(keychain: Keychain(copyMatching: { query, result in
            if (query as NSDictionary)[kSecAttrAccount as String] as? String == "org.lil.wallet.wallet.wallet" {
                let first = blocked.withLock { value in defer { value = true }; return !value }
                if first { entered.fulfill(); release.wait() }
            }
            return reader.copyMatching(query, result)
        }))
        let load = Task { await manager.reloadFromStore() }
        await fulfillment(of: [entered], timeout: 2)
        reader.attributes.append(reader.walletAttributes(id: "new-wallet"))
        reader.walletData["new-wallet"] = WalletCoreProxyTestVectors.walletCoreJSONPrivateKeyFixture
        let external = Task {
            notified.fulfill()
            await manager.handleExternalWalletStoreChange().value
        }
        await fulfillment(of: [notified], timeout: 2)
        release.signal()
        let loaded = await load.value
        await external.value

        XCTAssertTrue(loaded)
        XCTAssertEqual(Set(manager.wallets.map(\.id)), ["wallet", "new-wallet"])
        XCTAssertEqual(manager.loadState, .ready)
    }

    func testKnownExternalChangeWithholdsTheCatalogUntilAnUncancelledReadCoversIt() async throws {
        let reader = makeReader()
        let entered = expectation(description: "An external inventory read is pending")
        let hold = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let manager = WalletsManager(keychain: Keychain(copyMatching: { query, result in
            if (query as NSDictionary)[kSecReturnAttributes as String] as? Bool == true,
               hold.withLock({ value in defer { value = false }; return value }) {
                entered.fulfill()
                release.wait()
            }
            return reader.copyMatching(query, result)
        }))
        await assertWalletReload(manager)
        XCTAssertNotNil(manager.reviewCatalog())
        hold.withLock { $0 = true }
        let first = manager.handleExternalWalletStoreChange()
        XCTAssertTrue(manager.isStoreReady)
        XCTAssertNil(manager.reviewCatalog())
        await fulfillment(of: [entered], timeout: 3)
        reader.attributes = []
        let second = manager.handleExternalWalletStoreChange()
        second.cancel()
        release.signal()
        await first.value
        await second.value
        XCTAssertNil(manager.reviewCatalog())
        await assertWalletReload(manager)
        XCTAssertEqual(manager.reviewCatalog()?.orderedAccounts.count, 0)
    }

    func testCorruptAndMissingRecordsNeverPublishAPartialSnapshot() async throws {
        let reader = makeReader()
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        await assertWalletReload(manager)
        let original = manager.wallets
        reader.attributes.append(reader.walletAttributes(id: "broken"))
        reader.walletData["broken"] = Data("invalid".utf8)
        await assertWalletReload(manager, succeeds: false)
        XCTAssertEqual(manager.loadState, .failed(.corrupt))
        XCTAssertEqual(manager.wallets, original)
        reader.walletData["broken"] = nil
        await assertWalletReload(manager, succeeds: false)
        XCTAssertEqual(manager.loadState, .failed(.unavailable))
        XCTAssertEqual(manager.wallets, original)
        reader.attributes = [reader.walletAttributes(id: "wallet")]
        await assertWalletReload(manager)
        XCTAssertEqual(manager.wallets, original)
    }

    func testFailedStoreRejectsRetainedManagementAndExportActionsWithoutRetrying() async throws {
        let reader = makeReader()
        reader.passwordData = WalletCoreProxyTestVectors.walletCoreJSONPrivateKeyPassword
        let manager = WalletsManager(keychain: Keychain(
            copyMatching: reader.copyMatching,
            add: { _, _ in XCTFail("Failed storage must not be mutated"); return errSecParam },
            update: { _, _ in XCTFail("Failed storage must not be mutated"); return errSecParam },
            delete: { _ in XCTFail("Failed storage must not be mutated"); return errSecParam }
        ))
        await assertWalletReload(manager)
        let wallet = try XCTUnwrap(manager.wallets.first)
        let access = manager.accessForTesting()
        let challenge = try await manager.makeExportChallenge(wallet: wallet, kind: .privateKey)
        let grant = try XCTUnwrap(challenge.issueGrant(for: challenge.authorityID,
            credentialIdentity: .init(status: { .current })))
        defer { grant.invalidate() }
        reader.attributesStatus = errSecInteractionNotAllowed
        await assertWalletReload(manager, succeeds: false)
        let reads = reader.walletReadCount
        for action in 0..<6 {
            do {
                switch action {
                case 0: _ = try await manager.createWallet(access: access)
                case 1: try await manager.delete(wallet: wallet, access: access)
                case 2: try await manager.update(wallet: wallet, enabledAccounts: wallet.accounts, access: access)
                case 3: _ = try await manager.previewSession(wallet: wallet, access: access)
                case 4: _ = try await manager.makeExportChallenge(wallet: wallet, kind: .privateKey)
                default: _ = try await manager.exportPrivateKey(wallet: wallet, authorization: grant)
                }
                XCTFail("Unavailable storage accepted an action")
            } catch {}
        }
        XCTAssertEqual(reader.walletReadCount, reads)
        XCTAssertEqual(manager.loadState, .failed(.unavailable))
    }

    func testMalformedStoredAccountsPreserveSnapshotAndRejectEditsWithoutWriting() async throws {
        let reader = makeReader()
        let writes = Mutex(0)
        var publications = 0
        let manager = WalletsManager(keychain: Keychain(
            copyMatching: reader.copyMatching,
            add: { _, _ in writes.withLock { $0 += 1 }; return errSecParam },
            update: { _, _ in writes.withLock { $0 += 1 }; return errSecParam },
            delete: { _ in writes.withLock { $0 += 1 }; return errSecParam }
        ), publishLocalChange: { publications += 1 })
        await assertWalletReload(manager)
        let original = manager.wallets
        let wallet = try XCTUnwrap(original.first)
        let access = manager.accessForTesting()
        defer { access.invalidate() }
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(
            with: WalletCoreProxyTestVectors.walletCoreJSONPrivateKeyFixture
        ) as? [String: Any])
        let account: [String: Any] = [
            "address": wallet.accounts[0].address,
            "coin": wallet.accounts[0].coin.rawValue,
            "derivationPath": wallet.accounts[0].derivationPath,
        ]
        let malformedAccounts: [Any] = [
            [account, ["address": wallet.accounts[0].address]],
            [account, ["derivationPath": wallet.accounts[0].derivationPath]],
            [account, ["address": 42, "derivationPath": wallet.accounts[0].derivationPath]],
            [account, "invalid entry"] as [Any],
            ["unexpected": "object"],
            NSNull(),
        ]

        for malformed in malformedAccounts {
            var object = fixture
            object["activeAccounts"] = malformed
            let data = try JSONSerialization.data(withJSONObject: object)
            reader.walletData["wallet"] = data

            await assertWalletReload(manager, succeeds: false)

            XCTAssertEqual(manager.loadState, .failed(.corrupt))
            XCTAssertEqual(manager.wallets, original)
            XCTAssertEqual(publications, 1)
            XCTAssertNil(WalletSnapshotValidation.wallets(
                catalog: WalletAccountCatalog(snapshots: original), walletRecords: [(id: "wallet", data: data)]
            ))
            do {
                try await manager.update(wallet: wallet, enabledAccounts: wallet.accounts, access: access)
                XCTFail("Corrupt storage accepted an edit")
            } catch {}
            XCTAssertEqual(reader.walletData["wallet"], data)
            XCTAssertEqual(writes.withLock { $0 }, 0)
        }

        reader.walletData["wallet"] = WalletCoreProxyTestVectors.walletCoreJSONPrivateKeyFixture
        await assertWalletReload(manager)
        XCTAssertEqual(manager.wallets, original)
    }

    func testHealthyReloadPreservesValidityAndReadyPresentation() async throws {
        let reader = makeReader()
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        await assertWalletReload(manager)
        let token = try manager.repository.validity.token()
        let states = Mutex([WalletsManager.LoadState]())
        let observer = NotificationCenter.default.addObserver(forName: .walletsLoadStateChanged, object: manager, queue: .main) { _ in
            let state = MainActor.assumeIsolated { manager.loadState }
            states.withLock { $0.append(state) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await assertWalletReload(manager)
        XCTAssertNoThrow(try manager.repository.validity.validate(token))
        XCTAssertTrue(states.withLock { $0 }.isEmpty)
        XCTAssertTrue(manager.isStoreReady)
    }

    func testSupersededReloadCannotServeAnOlderPublishedCatalog() async throws {
        let reader = makeReader()
        let entered = expectation(description: "Refresh reached the changed store")
        let blockNextRead = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let manager = WalletsManager(keychain: Keychain(copyMatching: { query, result in
            if (query as NSDictionary)[kSecReturnAttributes as String] as? Bool == true,
               blockNextRead.withLock({ block in defer { block = false }; return block }) {
                entered.fulfill()
                release.wait()
            }
            return reader.copyMatching(query, result)
        }))
        await assertWalletReload(manager)
        reader.attributes = []
        blockNextRead.withLock { $0 = true }
        let refresh = Task { await manager.reloadFromStore() }
        await fulfillment(of: [entered], timeout: 5)

        let newerReadFinished = DispatchSemaphore(value: 0)
        let newer = Task.detached { [repository = manager.repository] in
            let result = await repository.load()
            newerReadFinished.signal()
            return result
        }
        release.signal()
        XCTAssertEqual(newerReadFinished.wait(timeout: .now() + 5), .success)
        guard case .loaded(let current) = await newer.value else { return XCTFail("Expected newer repository snapshot") }
        XCTAssertTrue(current.wallets.isEmpty)
        let succeeded = await refresh.value
        XCTAssertFalse(succeeded)
        XCTAssertTrue(manager.isStoreReady)
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet"])
        XCTAssertNil(manager.reviewCatalog())

        await assertWalletReload(manager)
        XCTAssertTrue(manager.wallets.isEmpty)
        XCTAssertNotNil(manager.reviewCatalog())
    }

    func testRepositoryFailureClosesAccessBeforeManagerPublicationAndRecoveryCannotReviveOldWork() async throws {
        let reader = makeReader()
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        await assertWalletReload(manager)
        let original = manager.wallets
        let validity = manager.repository.validity
        let token = try validity.token()
        reader.attributesStatus = errSecInteractionNotAllowed
        guard case .failed = await manager.repository.load() else { return XCTFail("Read failure was not observed") }
        XCTAssertEqual(manager.loadState, .ready)
        XCTAssertFalse(manager.isStoreReady)
        XCTAssertNil(manager.reviewCatalog())
        XCTAssertThrowsError(try validity.validate(token))
        reader.attributesStatus = errSecSuccess
        await assertWalletReload(manager)
        XCTAssertEqual(manager.wallets, original)
        XCTAssertThrowsError(try validity.validate(token))
        XCTAssertNoThrow(try validity.validate(validity.token()))
    }

    func testMutationRevisionAndOlderLoadCannotHealAnObservedFailure() throws {
        let validity = WalletStoreValidity()
        validity.recordLoad(revision: 1)
        let token = try validity.token()
        validity.recordLoad(revision: 3, failure: .corrupt)
        validity.recordLoad(revision: 2)
        validity.recordMutation(revision: 4)
        XCTAssertEqual(validity.snapshot.status, .failed(.corrupt))
        XCTAssertThrowsError(try validity.token())
        validity.recordLoad(revision: 5)
        XCTAssertThrowsError(try validity.validate(token))
        XCTAssertNoThrow(try validity.validate(validity.token()))
    }

    func testCancellationDuringFailurePublicationCannotRestoreReadyState() async throws {
        let reader = makeReader()
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        await assertWalletReload(manager)
        let observer = NotificationCenter.default.addObserver(forName: .walletsLoadStateChanged, object: manager, queue: .main) { _ in
            MainActor.assumeIsolated {
                if case .failed = manager.loadState { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        reader.attributesStatus = errSecInteractionNotAllowed
        let result = await manager.reloadFromStore()
        XCTAssertFalse(result)
        XCTAssertEqual(manager.loadState, .failed(.unavailable))
        XCTAssertFalse(manager.isStoreReady)
        XCTAssertEqual(manager.wallets.count, 1)
    }

    func testCancelledOldReloadFailureCannotClearItsReplacementOrReviveOldTokens() async throws {
        let reader = makeReader()
        let oldEntered = expectation(description: "Old read started")
        let newEntered = expectation(description: "Replacement read started")
        let oldRelease = DispatchSemaphore(value: 0)
        let newRelease = DispatchSemaphore(value: 0)
        defer { oldRelease.signal(); newRelease.signal() }
        let reads = Mutex(0)
        let manager = WalletsManager(keychain: Keychain(copyMatching: { query, result in
            if (query as NSDictionary)[kSecReturnAttributes as String] as? Bool == true {
                let count = reads.withLock { $0 += 1; return $0 }
                if count == 2 {
                    oldEntered.fulfill()
                    oldRelease.wait()
                    return errSecInteractionNotAllowed
                }
                if count == 3 { newEntered.fulfill(); newRelease.wait() }
            }
            return reader.copyMatching(query, result)
        }))
        await assertWalletReload(manager)
        let token = try manager.repository.validity.token()
        let old = Task { await manager.reloadFromStore() }
        await fulfillment(of: [oldEntered], timeout: 3)
        old.cancel()
        let replacement = Task { await manager.reloadFromStore() }
        oldRelease.signal()
        await fulfillment(of: [newEntered], timeout: 3)
        let oldResult = await old.value
        XCTAssertFalse(oldResult)
        XCTAssertFalse(manager.isStoreReady)
        XCTAssertThrowsError(try manager.repository.validity.validate(token))
        XCTAssertEqual(manager.wallets.count, 1)
        newRelease.signal()
        let restored = await replacement.value
        XCTAssertTrue(restored)
        XCTAssertTrue(manager.isStoreReady)
        XCTAssertThrowsError(try manager.repository.validity.validate(token))
    }

#if os(iOS) || os(visionOS)
    func testVaultCatalogReadFailureInvalidatesTokensAndPublishesFailure() async throws {
        for failure in [WalletsManager.LoadFailure.unavailable, .corrupt] {
            let reader = makeReader()
            reader.passwordData = WalletCoreProxyTestVectors.walletCoreJSONPrivateKeyPassword
            let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
            await assertWalletReload(manager)
            let token = try manager.repository.validity.token()
            let readSource = manager.makeSafariApprovalSourceReader()
            switch failure {
            case .unavailable: reader.walletReadStatuses["wallet"] = errSecInteractionNotAllowed
            case .corrupt: reader.attributes.append(reader.walletAttributes(id: "wallet"))
            }
            do {
                _ = try await readSource()
                XCTFail("The vault accepted a failed catalog read")
            } catch WalletCredentialError.failedToRead(errSecInteractionNotAllowed) {
                XCTAssertEqual(failure, .unavailable)
            } catch WalletsManager.LoadFailure.corrupt {
                XCTAssertEqual(failure, .corrupt)
            }
            XCTAssertEqual(manager.loadState, .failed(failure))
            XCTAssertThrowsError(try manager.repository.validity.validate(token))
            reader.walletReadStatuses = [:]
            reader.attributes = [reader.walletAttributes(id: "wallet")]
            var source = try await readSource()
            defer { source?.resetSecrets() }
            XCTAssertEqual(source?.wallets.map(\.walletID), ["wallet"])
            XCTAssertEqual(manager.loadState, .failed(failure))
            await assertWalletReload(manager)
            XCTAssertThrowsError(try manager.repository.validity.validate(token))
        }
    }

    func testCancelledVaultCatalogReadPreservesValidStore() async throws {
        let reader = makeReader()
        reader.passwordData = WalletCoreProxyTestVectors.walletCoreJSONPrivateKeyPassword
        let cancelEnumeration = Mutex(false)
        let manager = WalletsManager(keychain: Keychain(copyMatching: { query, result in
            if (query as NSDictionary)[kSecReturnAttributes as String] as? Bool == true,
               cancelEnumeration.withLock({ $0 }) { withUnsafeCurrentTask { $0?.cancel() } }
            return reader.copyMatching(query, result)
        }))
        await assertWalletReload(manager)
        let token = try manager.repository.validity.token()
        cancelEnumeration.withLock { $0 = true }
        let readSource = manager.makeSafariApprovalSourceReader()
        let task = Task { try await readSource() }
        do {
            _ = try await task.value
            XCTFail("Cancelled vault enumeration returned a snapshot")
        } catch is CancellationError {}
        XCTAssertEqual(manager.loadState, .ready)
        XCTAssertNoThrow(try manager.repository.validity.validate(token))
    }
#endif

    private func makeReader() -> KeychainCopyMatchingStub {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: "wallet")]
        reader.walletData = ["wallet": WalletCoreProxyTestVectors.walletCoreJSONPrivateKeyFixture]
        return reader
    }
}
