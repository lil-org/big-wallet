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
            .loading, .ready, .loading, .failed(.unavailable),
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

    func testCancelledRefreshPreservesSnapshotAndAllowsANewRetry() async throws {
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
        reader.attributesStatus = errSecInteractionNotAllowed
        refresh.cancel()
        release.signal()
        let cancelled = await refresh.value

        XCTAssertFalse(cancelled)
        XCTAssertEqual(manager.loadState, .ready)
        XCTAssertEqual(manager.wallets.map(\.id), ["wallet"])
        reader.attributesStatus = errSecSuccess
        reader.attributes = []
        await assertWalletReload(manager)
        XCTAssertTrue(manager.wallets.isEmpty)
        XCTAssertTrue(manager.hasLoadedSnapshot)
        XCTAssertTrue(manager.isStoreReady)
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
            await manager.handleExternalWalletStoreChange()
        }
        await fulfillment(of: [notified], timeout: 2)
        release.signal()
        let loaded = await load.value
        await external.value

        XCTAssertTrue(loaded)
        XCTAssertEqual(Set(manager.wallets.map(\.id)), ["wallet", "new-wallet"])
        XCTAssertEqual(manager.loadState, .ready)
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

    private func makeReader() -> KeychainCopyMatchingStub {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: "wallet")]
        reader.walletData = ["wallet": WalletCoreProxyTestVectors.walletCoreJSONPrivateKeyFixture]
        return reader
    }
}
