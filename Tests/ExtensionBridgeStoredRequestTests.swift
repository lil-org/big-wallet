// ∅ 2026 lil org

import Foundation
import Synchronization
import XCTest
#if os(macOS)
import Darwin
#endif
@testable import Big_Wallet

private func storedRequestNativeOwner(runtime: UUID = UUID()) -> ExtensionBridge.NativeDeliveryOwner {
    ExtensionBridge.NativeDeliveryOwner(
        runtimeInstanceIdentifier: runtime,
        processIdentifier: 42,
        processStartDate: Date(timeIntervalSince1970: 1_800_000_000),
        bundleURL: URL(fileURLWithPath: "/tmp/Big Wallet.app"),
        marketingVersion: "1.0.99",
        buildVersion: "148"
    )!
}

final class ExtensionBridgeStoredRequestTests: XCTestCase {
    private enum Failure: Error { case expectedValue, injectedWrite }

    private final class Clock: Sendable {
        private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date {
            get { value.withLock { $0 } }
            set { value.withLock { $0 = newValue } }
        }
    }

    private struct Fixture {
        let request: SafariRequest
        let ingress: ExtensionBridge.Ingress
    }

    private var rootURL: URL!
    private var clock: Clock!
    private var bridge: ExtensionBridge!
    private let nativeClaimConsents = LockedTestValue([(claim: ExtensionBridge.ApprovalClaim, consent: ReviewConsent)]())

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "extension-bridge-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        clock = Clock()
        let testClock = clock!
        bridge = makeBridge(clock: { testClock.now })
    }

    override func tearDownWithError() throws {
        nativeClaimConsents.value = []
        try? FileManager.default.removeItem(at: rootURL)
        bridge = nil
        clock = nil
        rootURL = nil
        try super.tearDownWithError()
    }

    func testAuthorityBootstrapPersistsLedgerAndProfileIdentityAndWarmReadsAreReadOnly() throws {
        let writes = LockedTestValue(0)
        let synchronizations = LockedTestValue(0)
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { data, url in writes.withValue { $0 += 1 }; try ApprovalStoreTestPersistence.write(data, url) },
            synchronizePublishedFile: { _ in synchronizations.withValue { $0 += 1 } }
        ))
        guard case .snapshot(let first) = store.configurationSnapshot(configurationKey: "https://wallet.example", profileIdentifier: nil) else {
            return XCTFail("Expected initial authority snapshot")
        }
        var observedRoot = try XCTUnwrap(rootURL)
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try observedRoot.setResourceValues(values)
        guard case .snapshot(let second) = store.configurationSnapshot(configurationKey: "https://wallet.example", profileIdentifier: nil),
              case .snapshot(let other) = store.configurationSnapshot(configurationKey: "https://other.example", profileIdentifier: nil) else {
            return XCTFail("Expected observational authority snapshots")
        }
        XCTAssertEqual(try observedRoot.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, false)
        XCTAssertEqual(writes.value, 2)
        XCTAssertEqual(synchronizations.value, 0)
        XCTAssertEqual(first.version, second.version)
        XCTAssertNotEqual(first.version.context, other.version.context)
        XCTAssertEqual((try storedProfile()["origins"] as? [String: Any])?.count, 0)
        XCTAssertNil(first.ethereumAccount)
        XCTAssertNil(first.solanaAccount)
    }

    @MainActor
    func testMissingOrMismatchedGrantInvalidatesSigningButPreservesCommittedResults() async throws {
        let accounts = [authorityTestAccount(), WalletAccountDescriptor(
            walletID: "solana-wallet", coin: .solana, normalizedAddress: String(repeating: "1", count: 32),
            derivationPath: "m/44'/501'/0'/0'")]
        for (providerIndex, account) in accounts.enumerated() {
            let baseID = 68_000 + providerIndex * 20
            let grant = try await grantAuthority(account, id: baseID)
            let originalData = try Data(contentsOf: defaultProfileURL)
            let grantResponse = try await deliveredAuthority(grant.handle)
            for (index, replaceAccount) in [false, true].enumerated() {
                try originalData.write(to: defaultProfileURL, options: .atomic)
                func admit(_ id: Int) async throws -> (request: SafariRequest, handle: ExtensionBridge.Handle) {
                    let fixture = try makeFixture(id: id)
                    var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.ingress.canonicalData) as? [String: Any])
                    if account.coin == .ethereum {
                        raw["name"] = "signPersonalMessage"
                    } else {
                        raw["provider"] = "solana"
                        raw["name"] = "signMessage"
                        raw["body"] = ["publicKey": account.normalizedAddress, "object": ["params": ["message": "1111"]]]
                    }
                    let signing = try authorityFixture(raw)
                    let handle = try accepted(await bridge.enqueue(ingress: signing.ingress, profileIdentifier: nil)).handle
                    return (signing.request, handle)
                }
                let pending = try await admit(baseID + index * 5 + 1)
                let claimed = try await admit(baseID + index * 5 + 2)
                let claim = try approvalClaim(await bridge.claim(handle: claimed.handle))
                let permit = try await reviewedExecution(claim)
                let broadcast = try await admittedBroadcast(account, id: baseID + index * 5 + 3)
                let broadcastClaim = try approvalClaim(await bridge.claim(handle: broadcast.handle))
                let broadcastPermit = try await reviewedExecution(broadcastClaim)
                let recovery = broadcastPermit.recoveryResponse
                let checkpoint = await prepareReviewedBroadcast(broadcastPermit, in: bridge)
                XCTAssertEqual(checkpoint, .persisted)
                let before = try await removalSnapshot()
                try mutateStoredPermissions { origins in
                    var origin = try XCTUnwrap(origins["https://wallet.example"] as? [String: Any])
                    let key = account.coin == .ethereum ? "ethereumAccount" : "solanaAccount"
                    if replaceAccount {
                        var replacement = try XCTUnwrap(origin[key] as? [String: Any])
                        replacement["walletID"] = "different-wallet"
                        origin[key] = replacement
                    } else {
                        origin.removeValue(forKey: key)
                    }
                    origins["https://wallet.example"] = origin
                }
                let current = await bridge.authorityIsCurrent(handle: claimed.handle)
                XCTAssertFalse(current)
                let disconnected = try await removalSnapshot()
                XCTAssertNil(disconnected.ethereumAccount)
                XCTAssertNil(disconnected.solanaAccount)
                XCTAssertGreaterThan(disconnected.version.revisions.ethereum, before.version.revisions.ethereum)
                XCTAssertGreaterThan(disconnected.version.revisions.solana, before.version.revisions.solana)
                guard case .responded = await bridge.claim(handle: pending.handle) else {
                    return XCTFail("Missing grants must retire pending signing")
                }
                _ = await completeReviewedExecution(permit, in: bridge)
                for handle in [pending.handle, claimed.handle] {
                    let delivery = try await deliveredAuthority(handle)
                    XCTAssertEqual((delivery.response["error"] as? [String: Any])?["code"] as? Int, 4100)
                }
                broadcastPermit.releaseLease()
                let broadcastDelivery = try await deliveredAuthority(broadcast.handle)
                XCTAssertTrue(NSDictionary(dictionary: recovery.json).isEqual(to: broadcastDelivery.response))
                let retainedGrant = try await deliveredAuthority(grant.handle)
                XCTAssertTrue(NSDictionary(dictionary: grantResponse.response).isEqual(to: retainedGrant.response))
            }
        }
    }

    func testWalletRemovalRepairsPermissionsInInactiveProfiles() async throws {
        let inactiveProfile = UUID()
        _ = try await grantAuthority(authorityTestAccount(), id: 68_100, profileIdentifier: inactiveProfile)
        let url = profileURL(inactiveProfile)
        var profile = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), options: [], format: nil) as? [String: Any])
        var origins = try XCTUnwrap(profile["origins"] as? [String: Any])
        origins["https://wallet.example"] = "unreadable permissions"
        profile["origins"] = origins
        try PropertyListSerialization.data(fromPropertyList: profile, format: .binary, options: 0)
            .write(to: url, options: .atomic)

        let removed = LockedTestValue(false)
        try removalStore().withRevokedWalletAuthority(matching: .wallet(id: "unrelated-wallet")) { removed.value = true }
        XCTAssertTrue(removed.value)
        let recovered = try await removalSnapshot(profileIdentifier: inactiveProfile)
        XCTAssertNil(recovered.ethereumAccount)
        XCTAssertNil(recovered.solanaAccount)
    }

    @MainActor
    func testManualSwitchPreservesExactDuplicateWalletGrantsAfterReload() async throws {
        let ethereum = WalletAccountDescriptor(walletID: "second-wallet", coin: .ethereum,
            normalizedAddress: authorityTestAccount().normalizedAddress, derivationPath: "m/44'/60'/0'/0/0")
        let solana = WalletAccountDescriptor(walletID: "second-wallet", coin: .solana,
            normalizedAddress: String(repeating: "1", count: 32), derivationPath: "m/44'/501'/0'/0'")
        let granted = [ethereum, solana]
        let duplicates = granted.map {
            WalletAccountDescriptor(walletID: "first-wallet", account: $0.account)
        }
        let descriptors = duplicates + granted
        let catalog = WalletReviewCatalog(
            identity: .init(generation: nil, catalogData: try WalletAccountCatalog(accounts: descriptors).canonicalData()),
            orderedAccounts: descriptors.map(\.specificAccount)
        )
        _ = try await grantAuthority(ethereum, id: 68_110)
        _ = try await grantAuthority(solana, id: 68_111)
        let processor = DappRequestProcessor()

        for (id, chainID) in [(68_112, "0x1"), (68_113, "0xa")] {
            let manual = try makeManualFixture(id: id, enqueueAttempt: attempt(for: id), latestConfigurations: [])
            let handle = try accepted(await bridge.enqueue(ingress: manual.ingress, profileIdentifier: nil)).handle
            let testClock = try XCTUnwrap(clock)
            bridge = makeBridge(clock: { testClock.now })
            guard case .found(let snapshot) = await bridge.load(handle: handle),
                  let binding = snapshot.requestBinding,
                  case .approval(let intent) = processor.prepare(binding, catalog: catalog),
                  case .switchAccount(let action) = intent.action else {
                return XCTFail("Expected the persisted manual switch")
            }
            XCTAssertEqual(Set(action.selectedAccounts.map {
                WalletAccountDescriptor(walletID: $0.walletId, account: $0.account)
            }), Set(granted))
            let missingGrantedAccounts = WalletReviewCatalog(
                identity: catalog.identity, orderedAccounts: duplicates.map(\.specificAccount)
            )
            guard case .approval(let unavailableIntent) = processor.prepare(binding, catalog: missingGrantedAccounts),
                  case .switchAccount(let unavailable) = unavailableIntent.action else {
                return XCTFail("Expected manual selection without the granted wallets")
            }
            XCTAssertTrue(unavailable.selectedAccounts.isEmpty)

            let decision = DappApprovalDecision.accountSelection(.init(
                accounts: action.selectedAccounts.map {
                    WalletAccountDescriptor(walletID: $0.walletId, account: $0.account)
                },
                ethereumChainID: chainID
            ))
            let approval = try resolvedApprovalForTesting(
                snapshot: snapshot, action: .switchAccount(action), decision: decision,
                accounts: catalog.orderedAccounts, approvedAt: clock.now
            )
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            guard claim.adoptForExecution(),
                  case .authorized(let permit) = await bridge.authorize(claim: claim, approval: approval),
                  case .completed(let result) = await processor.execute(permit: permit, signer: nil) else {
                return XCTFail("Expected the approved account selection")
            }
            let completion = await bridge.complete(permit: permit, result: result)
            XCTAssertEqual(completion, .persisted)
            let current = try await removalSnapshot()
            XCTAssertEqual(current.ethereumAccount, ethereum)
            XCTAssertEqual(current.solanaAccount, solana)
            XCTAssertEqual(current.ethereumChainId, chainID)
            let acknowledged = await bridge.acknowledgeResponse(handle: handle, configurationKey: binding.request.configurationKey)
            XCTAssertEqual(acknowledged, .persisted)
        }

        let beforeRemoval = try await removalSnapshot()
        try removalStore().withRevokedWalletAuthority(matching: .wallet(id: "first-wallet")) {}
        let afterRemoval = try await removalSnapshot()
        XCTAssertEqual(afterRemoval.version, beforeRemoval.version)
        XCTAssertEqual(afterRemoval.ethereumAccount, ethereum)
        XCTAssertEqual(afterRemoval.solanaAccount, solana)
    }

    func testMalformedPermissionsDisconnectWholeProfileAndPermitReconnection() async throws {
        let account = authorityTestAccount()
        let solana = WalletAccountDescriptor(walletID: account.walletID, coin: .solana,
            normalizedAddress: String(repeating: "1", count: 32), derivationPath: "m/44'/501'/0'/0'")
        _ = try await grantAuthority(account, id: 64_000, chainId: "0xa")
        _ = try await grantAuthority(solana, id: 64_001)
        _ = try await grantAuthority(account, id: 64_002, host: "healthy.example", chainId: "0xa")
        _ = try await grantAuthority(account, id: 64_005, host: "second.example")
        let otherProfile = UUID()
        _ = try await grantAuthority(account, id: 64_003, profileIdentifier: otherProfile)
        let before = try await removalSnapshot()
        let secondBefore = try await removalSnapshot(host: "second.example")
        let healthy = try await removalSnapshot(host: "healthy.example")
        let otherProfileData = try Data(contentsOf: profileURL(otherProfile))
        let originalData = try Data(contentsOf: defaultProfileURL)
        let original = try storedProfile()
        let origins = try XCTUnwrap(original["origins"] as? [String: Any])
        let originalOrigin = try XCTUnwrap(origins["https://wallet.example"] as? [String: Any])
        let originalSequence = try XCTUnwrap(original["authoritySequence"] as? Int)
        var malformedValues: [Any] = ["unreadable permissions", ["unknown": true]]
        for (key, value): (String, Any) in [
            ("ethereumAccount", "invalid account"),
            ("solanaAccount", ["walletID": "incomplete"]),
            ("ethereumChainId", "0X1"),
            ("revisions", ["ethereum": -1, "solana": 0]),
            ("revisions", ["ethereum": originalSequence + 1, "solana": 0]),
        ] {
            var origin = originalOrigin
            origin[key] = value
            malformedValues.append(origin)
        }

        for (index, value) in malformedValues.enumerated() {
            try originalData.write(to: defaultProfileURL, options: .atomic)
            try mutateStoredPermissions {
                $0["https://wallet.example"] = value
                $0["https://second.example"] = ["unknown": true]
            }
            if index % 3 == 1 {
                guard case .available = await bridge.list(profileIdentifier: nil) else {
                    return XCTFail("Request listing must recover incompatible permissions")
                }
            } else if index % 3 == 2 {
                await bridge.performMaintenance(profileIdentifier: nil)
                let maintained = try XCTUnwrap(storedProfile()["origins"] as? [String: Any])
                let origin = try XCTUnwrap(maintained["https://wallet.example"] as? [String: Any])
                XCTAssertNil(origin["ethereumAccount"])
            }
            let recovered = try await removalSnapshot()
            XCTAssertNil(recovered.ethereumAccount)
            XCTAssertNil(recovered.solanaAccount)
            XCTAssertEqual(recovered.ethereumChainId, "0x1")
            XCTAssertEqual(recovered.version.context, before.version.context)
            XCTAssertGreaterThan(recovered.version.revisions.ethereum, originalSequence)
            XCTAssertEqual(recovered.version.revisions.solana, recovered.version.revisions.ethereum)
            let secondRecovered = try await removalSnapshot(host: "second.example")
            XCTAssertNil(secondRecovered.ethereumAccount)
            XCTAssertEqual(secondRecovered.version.context, secondBefore.version.context)
            XCTAssertEqual(secondRecovered.version.revisions, recovered.version.revisions)
            let retained = try await removalSnapshot(host: "healthy.example")
            XCTAssertNil(retained.ethereumAccount)
            XCTAssertEqual(retained.ethereumChainId, "0x1")
            XCTAssertEqual(retained.version.context, healthy.version.context)
            XCTAssertEqual(retained.version.revisions, recovered.version.revisions)
            XCTAssertEqual(try Data(contentsOf: profileURL(otherProfile)), otherProfileData)
            let repeated = try await removalSnapshot()
            XCTAssertEqual(repeated.version, recovered.version)
        }

        _ = try await grantAuthority(account, id: 64_004)
        let reconnected = try await removalSnapshot()
        XCTAssertEqual(reconnected.ethereumAccount, account)
        XCTAssertNil(reconnected.solanaAccount)
    }

    func testDecimalDictionaryRevisionTriggersPermissionRecoveryAfterRestart() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 64_020, chainId: "0xa")
        let before = try await removalSnapshot()
        XCTAssertEqual(before.ethereumAccount, account)
        let encoded = try PropertyListEncoder().encode(Decimal(before.version.revisions.ethereum))
        var decimal = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: encoded, options: [], format: nil
        ) as? [String: Any])
        decimal["unexpected"] = ["ignored": true]
        try mutateStoredPermissions { origins in
            var origin = try XCTUnwrap(origins["https://wallet.example"] as? [String: Any])
            var revisions = try XCTUnwrap(origin["revisions"] as? [String: Any])
            revisions["ethereum"] = decimal
            origin["revisions"] = revisions
            origins["https://wallet.example"] = origin
        }

        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .snapshot(let recovered) = await observer.configurationSnapshot(
            configurationKey: "https://wallet.example", profileIdentifier: nil
        ) else { return XCTFail("Expected malformed revision recovery") }
        XCTAssertNil(recovered.ethereumAccount)
        XCTAssertNil(recovered.solanaAccount)
        XCTAssertEqual(recovered.ethereumChainId, "0x1")
        XCTAssertEqual(recovered.version.context, before.version.context)
        XCTAssertGreaterThan(recovered.version.revisions.ethereum, before.version.revisions.ethereum)
        XCTAssertEqual(recovered.version.revisions.solana, recovered.version.revisions.ethereum)
        let origins = try XCTUnwrap(storedProfile()["origins"] as? [String: Any])
        let origin = try XCTUnwrap(origins["https://wallet.example"] as? [String: Any])
        let revisions = try XCTUnwrap(origin["revisions"] as? [String: Int])
        XCTAssertEqual(revisions["ethereum"], recovered.version.revisions.ethereum)
    }

    func testPermissionRecoveryDiscardsInvalidKeysMissingOriginsAndOversizedMaps() async throws {
        _ = try await grantAuthority(authorityTestAccount(), id: 64_060)
        let original = try storedProfile()
        let sequence = try XCTUnwrap(original["authoritySequence"] as? Int)
        let originalOrigins = try XCTUnwrap(original["origins"] as? [String: Any])
        let origin = try XCTUnwrap(originalOrigins["https://wallet.example"])
        var invalidKey = originalOrigins
        invalidKey["not an origin"] = origin
        var excessiveCount = Dictionary(uniqueKeysWithValues: (0...ExtensionRequestProfile.maximumOrigins).map {
            ("https://site-\($0).example", origin)
        })
        excessiveCount["https://wallet.example"] = origin
        var largeOrigins = Dictionary(uniqueKeysWithValues: (0..<400).map { index in
            let component = String(repeating: "%E4%B8%AD", count: 26)
            let key = "file:///tmp/\(index)/" + Array(repeating: component, count: 12).joined(separator: "/")
            XCTAssertTrue(ExtensionRequestProfile.validConfigurationKey(key))
            return (key, origin)
        })
        largeOrigins["https://wallet.example"] = origin
        let largeData = try PropertyListSerialization.data(fromPropertyList: largeOrigins, format: .binary, options: 0)
        XCTAssertGreaterThan(largeData.count, ExtensionRequestProfile.maximumAuthorityBytes)

        for origins in [invalidKey, [:], excessiveCount, largeOrigins] {
            var profile = original
            profile["origins"] = origins
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .binary, options: 0)
            XCTAssertLessThan(data.count, ExtensionRequestProfile.maximumProfileBytes)
            try data.write(to: defaultProfileURL, options: .atomic)
            let recovered = try await removalSnapshot()
            XCTAssertNil(recovered.ethereumAccount)
            XCTAssertEqual(recovered.version.revisions.ethereum, sequence + 1)
            XCTAssertEqual(recovered.version.revisions.solana, sequence + 1)
            let persisted = try storedProfile()
            XCTAssertEqual((persisted["origins"] as? [String: Any])?.count, 1)
            XCTAssertEqual(persisted["reclaimedAuthorityRevision"] as? Int, sequence + 1)
            let repeated = try await removalSnapshot()
            XCTAssertEqual(repeated.version, recovered.version)
        }
    }

    func testPermissionRecoveryRejectsFutureRecordRevisionsAndExhaustedSequence() async throws {
        _ = try await grantAuthority(authorityTestAccount(), id: 64_070)
        let original = try storedProfile()
        let sequence = try XCTUnwrap(original["authoritySequence"] as? Int)
        for exhausted in [false, true] {
            var profile = original
            profile["origins"] = "corrupt permissions"
            if exhausted {
                profile["authoritySequence"] = ExtensionRequestProfile.maximumRevision
            } else {
                var records = try XCTUnwrap(profile["records"] as? [[String: Any]])
                var authority = try XCTUnwrap(records[0]["authority"] as? [String: Any])
                authority["revisions"] = ["ethereum": sequence + 1, "solana": sequence]
                records[0]["authority"] = authority
                profile["records"] = records
            }
            try PropertyListSerialization.data(fromPropertyList: profile, format: .binary, options: 0)
                .write(to: defaultProfileURL, options: .atomic)
            try await assertStoredProfileUnavailableAndUnchanged()
        }
    }

    func testPermissionRecoveryPreservesDisconnectReceiptsAndRejectsDamagedReceipts() async throws {
        _ = try await grantAuthority(authorityTestAccount(), id: 64_080)
        _ = try await grantAuthority(authorityTestAccount(), id: 64_081, host: "healthy.example")
        let authority = try await removalSnapshot()
        let attempt = attempt(for: 64_082)
        guard case .revoked = await bridge.revoke(configurationKey: "https://wallet.example", provider: .ethereum,
            attempt: attempt, expected: authority.version, profileIdentifier: nil) else {
            return XCTFail("Expected disconnect receipt")
        }
        let original = try storedProfile()
        let receipts = try XCTUnwrap(original["mutationReceipts"] as? [[String: Any]])
        try mutateStoredPermissions { $0["https://healthy.example"] = "corrupt permissions" }
        let recovered = try await removalSnapshot()
        let healthy = try await removalSnapshot(host: "healthy.example")
        XCTAssertNil(healthy.ethereumAccount)
        let retainedReceipts = try XCTUnwrap(storedProfile()["mutationReceipts"] as? [[String: Any]])
        XCTAssertTrue(NSArray(array: receipts).isEqual(to: retainedReceipts))
        guard case .revoked(let replayed) = await bridge.revoke(configurationKey: "https://wallet.example", provider: .ethereum,
            attempt: attempt, expected: authority.version, profileIdentifier: nil) else {
            return XCTFail("Expected receipt replay after reset")
        }
        XCTAssertEqual(replayed.version, recovered.version)
        XCTAssertNil(replayed.ethereumAccount)

        for malformed: Any in ["corrupt receipts", receipts + receipts] {
            var profile = original
            profile["origins"] = "corrupt permissions"
            profile["mutationReceipts"] = malformed
            try PropertyListSerialization.data(fromPropertyList: profile, format: .binary, options: 0)
                .write(to: defaultProfileURL, options: .atomic)
            try await assertStoredProfileUnavailableAndUnchanged()
        }
    }

    func testIncompatiblePermissionContainerDisconnectsAllOriginsWithoutDiscardingRequestHistory() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 64_050)
        _ = try await grantAuthority(account, id: 64_051, host: "second.example")
        let completed = try makeFixture(id: 64_052)
        let completedHandle = try accepted(await bridge.enqueue(ingress: completed.ingress, profileIdentifier: nil)).handle
        let completion = await bridge.completeImmediate(handle: completedHandle, resolution: immediateResolution(for: completed.request))
        XCTAssertEqual(completion, .persisted)
        let before = try await removalSnapshot()
        let secondBefore = try await removalSnapshot(host: "second.example")
        let original = try storedProfile()
        let originalSequence = try XCTUnwrap(original["authoritySequence"] as? Int)
        let records = try XCTUnwrap(original["records"] as? [[String: Any]])
        let malformedContainers: [Any?] = [nil, "incompatible permissions", ["invalid", "container"]]

        for retainHistory in [true, false] {
            for container in malformedContainers {
                var profile = original
                profile["origins"] = container
                if !retainHistory { profile["records"] = [[String: Any]]() }
                try PropertyListSerialization.data(fromPropertyList: profile, format: .binary, options: 0)
                    .write(to: defaultProfileURL, options: .atomic)

                let recovered = try await removalSnapshot()
                let second = try await removalSnapshot(host: "second.example")
                XCTAssertNil(recovered.ethereumAccount)
                XCTAssertNil(second.ethereumAccount)
                XCTAssertEqual(recovered.version.context, before.version.context)
                XCTAssertEqual(second.version.context, secondBefore.version.context)
                XCTAssertGreaterThan(recovered.version.revisions.ethereum, originalSequence)
                XCTAssertEqual(recovered.version.revisions.solana, recovered.version.revisions.ethereum)
                XCTAssertEqual(second.version.revisions, recovered.version.revisions)
                let persisted = try storedProfile()
                XCTAssertEqual(persisted["authoritySequence"] as? Int, recovered.version.revisions.ethereum)
                let persistedRecords = try XCTUnwrap(persisted["records"] as? [[String: Any]])
                if retainHistory {
                    XCTAssertTrue(NSArray(array: records).isEqual(to: persistedRecords))
                    let replay = try accepted(await bridge.enqueue(ingress: completed.ingress, profileIdentifier: nil))
                    XCTAssertEqual(replay.handle, completedHandle)
                    XCTAssertFalse(replay.approvalRequired)
                    let delivery = try await deliveredAuthority(completedHandle)
                    XCTAssertEqual(delivery.response["result"] as? String, "0xsigned")
                    XCTAssertEqual((delivery.state["ethereum"] as? [String: String])?["address"], "")
                } else {
                    XCTAssertTrue(persistedRecords.isEmpty)
                    XCTAssertEqual((persisted["origins"] as? [String: Any])?.count, 0)
                }
                XCTAssertEqual(persisted["reclaimedAuthorityRevision"] as? Int, recovered.version.revisions.ethereum)
                let unknown = try await removalSnapshot(host: "unknown.example")
                XCTAssertEqual(unknown.version.revisions, recovered.version.revisions)
                let repeated = try await removalSnapshot()
                XCTAssertEqual(repeated.version, recovered.version)
            }
        }
    }

    @MainActor
    func testPermissionRecoveryFencesOutstandingApprovalsWithoutLosingBroadcastOrCompletedResponses() async throws {
        let account = authorityTestAccount()
        let grant = try await grantAuthority(account, id: 64_010)
        let completed = try makeFixture(id: 64_011)
        let completedHandle = try accepted(await bridge.enqueue(ingress: completed.ingress, profileIdentifier: nil)).handle
        let completion = await bridge.completeImmediate(handle: completedHandle, resolution: immediateResolution(for: completed.request))
        XCTAssertEqual(completion, .persisted)
        let completedResponse = try await deliveredAuthority(completedHandle)
        let pending = try await admittedSigning(account, id: 64_012)
        let claimed = try await admittedSigning(account, id: 64_013)
        let claim = try approvalClaim(await bridge.claim(handle: claimed.handle))
        let permit = try await reviewedExecution(claim)
        let selection = try makeManualFixture(id: 64_014, enqueueAttempt: attempt(for: 64_014), latestConfigurations: [])
        let selectionHandle = try accepted(await bridge.enqueue(ingress: selection.ingress, profileIdentifier: nil)).handle
        let selectionClaim = try approvalClaim(await bridge.claim(handle: selectionHandle))
        let selectionPermit = try await reviewedExecution(selectionClaim, accounts: [account])
        let broadcast = try makeTransactionFixture(id: 64_015)
        let broadcastHandle = try accepted(await bridge.enqueue(ingress: broadcast.ingress, profileIdentifier: nil)).handle
        let broadcastClaim = try approvalClaim(await bridge.claim(handle: broadcastHandle))
        let broadcastPermit = try await reviewedExecution(broadcastClaim)
        _ = broadcastPermit.recoveryResponse
        let checkpoint = await prepareReviewedBroadcast(broadcastPermit, in: bridge)
        XCTAssertEqual(checkpoint, .persisted)
        _ = try await grantAuthority(account, id: 64_016, host: "healthy.example")
        let healthySigning = try makeFixture(id: 64_017, name: "signPersonalMessage", host: "healthy.example")
        let healthyHandle = try accepted(await bridge.enqueue(ingress: healthySigning.ingress, profileIdentifier: nil)).handle
        let recovery = try makeFixture(id: 64_018, host: "healthy.example")
        let recoveryHandle = try accepted(await bridge.enqueue(ingress: recovery.ingress, profileIdentifier: nil)).handle
        let liveBroadcast = try makeTransactionFixture(id: 64_019, host: "healthy.example")
        let liveHandle = try accepted(await bridge.enqueue(ingress: liveBroadcast.ingress, profileIdentifier: nil)).handle
        let liveClaim = try approvalClaim(await bridge.claim(handle: liveHandle))
        let livePermit = try await reviewedExecution(liveClaim)
        let liveCheckpoint = await prepareReviewedBroadcast(livePermit, in: bridge)
        XCTAssertEqual(liveCheckpoint, .persisted)
        let originalRecords = try XCTUnwrap(storedProfile()["records"] as? [[String: Any]])
        let originalCheckpoint = try XCTUnwrap(originalRecords.first { $0["id"] as? Int == broadcast.request.id })
        let originalCompleted = try XCTUnwrap(originalRecords.first { $0["id"] as? Int == completed.request.id })

        try mutateStoredPermissions { $0["https://wallet.example"] = "incompatible permissions" }
        let disconnected = try await removalSnapshot()
        XCTAssertNil(disconnected.ethereumAccount)
        for handle in [pending.handle, claimed.handle, selectionHandle, healthyHandle] {
            let delivery = try await deliveredAuthority(handle)
            XCTAssertEqual((delivery.response["error"] as? [String: Any])?["code"] as? Int, 4100)
        }
        let recoveredRecords = try XCTUnwrap(storedProfile()["records"] as? [[String: Any]])
        let retainedCheckpoint = try XCTUnwrap(recoveredRecords.first { $0["id"] as? Int == broadcast.request.id })
        let retainedCompleted = try XCTUnwrap(recoveredRecords.first { $0["id"] as? Int == completed.request.id })
        XCTAssertTrue(NSDictionary(dictionary: originalCheckpoint).isEqual(to: retainedCheckpoint))
        XCTAssertTrue(NSDictionary(dictionary: originalCompleted).isEqual(to: retainedCompleted))
        let liveLock = CrossProcessFileLock(fileURL: operationLockURL(liveHandle))
        XCTAssertFalse(try liveLock.tryAcquireExisting())
        let liveCompletion = await completeReviewedExecution(livePermit, in: bridge)
        XCTAssertEqual(liveCompletion, .persisted)
        let liveResponse = try await deliveredAuthority(liveHandle)
        XCTAssertEqual(liveResponse.response as NSDictionary, livePermit.response.json as NSDictionary)
        XCTAssertEqual(liveResponse.response["approvalCommitted"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: operationLockURL(liveHandle).path))
        let recoveryCompletion = await bridge.completeImmediate(handle: recoveryHandle, resolution: immediateResolution(for: recovery.request))
        XCTAssertEqual(recoveryCompletion, .persisted)
        let recoveredAddress = try await deliveredAuthority(recoveryHandle)
        XCTAssertEqual(recoveredAddress.response["result"] as? String, "0xsigned")

        _ = await completeReviewedExecution(selectionPermit, in: bridge)
        _ = await completeReviewedExecution(permit, in: bridge)
        let stillDisconnected = try await removalSnapshot()
        XCTAssertNil(stillDisconnected.ethereumAccount)
        let completedReplay = try accepted(await bridge.enqueue(ingress: completed.ingress, profileIdentifier: nil))
        XCTAssertEqual(completedReplay.handle, completedHandle)
        XCTAssertFalse(completedReplay.approvalRequired)
        let retainedResponse = try await deliveredAuthority(completedHandle)
        XCTAssertTrue(NSDictionary(dictionary: completedResponse.response).isEqual(to: retainedResponse.response))
        let retainedGrant = try await deliveredAuthority(grant.handle)
        XCTAssertEqual(retainedGrant.response["result"] as? [String], [account.normalizedAddress])
        XCTAssertEqual((retainedGrant.state["ethereum"] as? [String: String])?["address"], "")

        broadcastPermit.releaseLease()
        let deliveredBroadcast = try await deliveredAuthority(broadcastHandle)
        XCTAssertEqual((deliveredBroadcast.response["error"] as? [String: Any])?["code"] as? Int,
            ProviderResponseError.transactionSubmissionUnknownCode)
        XCTAssertEqual(deliveredBroadcast.response["approvalCommitted"] as? Bool, true)
        let broadcastReplay = try accepted(await bridge.enqueue(ingress: broadcast.ingress, profileIdentifier: nil))
        XCTAssertEqual(broadcastReplay.handle, broadcastHandle)
        XCTAssertFalse(broadcastReplay.approvalRequired)
    }

    func testPermissionRecoveryDoesNotPublishSnapshotWhenStorageIsUnavailable() async throws {
        _ = try await grantAuthority(authorityTestAccount(), id: 64_020)
        try mutateStoredPermissions { $0["https://wallet.example"] = "incompatible permissions" }
        let corruptedData = try Data(contentsOf: defaultProfileURL)
        let writes = LockedTestValue(0)
        let unreadable = makeBridge(clock: { [clock = clock!] in clock.now }, atomicWrite: { _, _ in
            writes.withValue { $0 += 1 }
            throw Failure.injectedWrite
        }, readData: { _ in throw Failure.injectedWrite })
        guard case .unavailable = await unreadable.configurationSnapshot(
            configurationKey: "https://wallet.example", profileIdentifier: nil
        ) else { return XCTFail("Read failures must not fabricate disconnected authority") }
        XCTAssertEqual(writes.value, 0)
        let unwritable = makeBridge(clock: { [clock = clock!] in clock.now }, atomicWrite: { _, _ in
            writes.withValue { $0 += 1 }
            throw Failure.injectedWrite
        })
        for _ in 0..<2 {
            guard case .unavailable = await unwritable.configurationSnapshot(
                configurationKey: "https://wallet.example", profileIdentifier: nil
            ) else { return XCTFail("Recovery must persist before returning disconnected authority") }
        }
        XCTAssertGreaterThan(writes.value, 0)
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), corruptedData)
        let recovered = try await removalSnapshot()
        XCTAssertNil(recovered.ethereumAccount)
    }

    func testPermissionRecoveryRequiresSynchronizationAfterAmbiguousPublication() async throws {
        _ = try await grantAuthority(authorityTestAccount(), id: 64_030)
        try mutateStoredPermissions { $0["https://wallet.example"] = "incompatible permissions" }
        let corruptedData = try Data(contentsOf: defaultProfileURL)
        let synchronizations = LockedTestValue(0)
        for synchronizationSucceeds in [false, true] {
            try corruptedData.write(to: defaultProfileURL, options: .atomic)
            let observer = makeBridge(clock: { [clock = clock!] in clock.now }, atomicWrite: { data, url in
                try ApprovalStoreTestPersistence.write(data, url)
                throw Failure.injectedWrite
            }, synchronizePublishedFile: { _ in
                synchronizations.withValue { $0 += 1 }
                if !synchronizationSucceeds { throw Failure.injectedWrite }
            })
            let result = await observer.configurationSnapshot(configurationKey: "https://wallet.example", profileIdentifier: nil)
            if synchronizationSucceeds {
                guard case .snapshot(let recovered) = result else {
                    return XCTFail("Durable read-back should accept a published recovery")
                }
                XCTAssertNil(recovered.ethereumAccount)
            } else {
                guard case .unavailable = result else {
                    return XCTFail("An unsynchronized recovery must remain unavailable")
                }
            }
        }
        XCTAssertEqual(synchronizations.value, 2)
    }

    func testPermissionRecoveryDoesNotMaskUnsupportedEnvelopeOrDamagedRequestHistory() async throws {
        _ = try await grantAuthority(authorityTestAccount(), id: 64_040)
        let pending = try await admittedSigning(authorityTestAccount(), id: 64_041)
        try mutateStoredPermissions { $0["https://wallet.example"] = "incompatible permissions" }
        let original = try storedProfile()
        var invalidProfiles = [[String: Any]]()
        for (key, value): (String, Any) in [
            ("schemaVersion", Int.max),
            ("workflowVersion", Int.max),
            ("profileIdentifier", UUID().uuidString),
            ("authorityEpoch", "not-an-epoch"),
            ("reclaimedAuthorityRevision", -1),
            ("reclaimedAuthorityRevision", Int.max),
        ] {
            var profile = original
            profile[key] = value
            invalidProfiles.append(profile)
        }
        var missingRevision = original
        missingRevision.removeValue(forKey: "reclaimedAuthorityRevision")
        invalidProfiles.append(missingRevision)
        var invalidRecord = original
        var records = try XCTUnwrap(invalidRecord["records"] as? [[String: Any]])
        records[0]["requestFingerprint"] = "invalid transaction history"
        invalidRecord["records"] = records
        invalidProfiles.append(invalidRecord)
        var invalidPending = original
        var pendingRecords = try XCTUnwrap(original["records"] as? [[String: Any]])
        let pendingIndex = try XCTUnwrap(pendingRecords.firstIndex { $0["id"] as? Int == pending.handle.id })
        pendingRecords[pendingIndex]["requestFingerprint"] = Data(repeating: 0, count: 32)
        invalidPending["records"] = pendingRecords
        invalidProfiles.append(invalidPending)

        for profile in invalidProfiles {
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .binary, options: 0)
            try data.write(to: defaultProfileURL, options: .atomic)
            guard case .unavailable = await bridge.configurationSnapshot(
                configurationKey: "https://wallet.example", profileIdentifier: nil
            ) else { return XCTFail("Permission recovery cannot discard an invalid envelope or request history") }
            guard case .unavailable = await bridge.list(profileIdentifier: nil) else {
                return XCTFail("Maintenance cannot repair an invalid envelope or request history")
            }
            XCTAssertEqual(try Data(contentsOf: defaultProfileURL), data)
        }
    }

    func testNativeAuthorityRejectsClientInventedGrantsAndRevisions() async throws {
        let template = try makeFixture(id: 60_001)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: template.ingress.canonicalData) as? [String: Any])
        object["name"] = "signPersonalMessage"
        let unauthorized = try authorityFixture(object)
        guard case .unauthorized = await bridge.enqueue(ingress: unauthorized.ingress, profileIdentifier: nil) else {
            return XCTFail("Disconnected origin cannot request a signature")
        }
        var authority = template.ingress.authority.json
        authority["revisions"] = ["ethereum": 7, "solana": 0]
        object["name"] = "requestAccounts"
        object["authority"] = authority
        let forged = try authorityFixture(object)
        guard case .unauthorized = await bridge.enqueue(ingress: forged.ingress, profileIdentifier: nil) else {
            return XCTFail("Client revisions cannot create authority")
        }
        guard case .snapshot(let current) = await bridge.configurationSnapshot(configurationKey: template.request.configurationKey, profileIdentifier: nil) else {
            return XCTFail("Expected authority")
        }
        XCTAssertEqual(current.version.revisions.ethereum, 0)
        XCTAssertNil(current.ethereumAccount)
    }

    func testNativeGrantCommitIsAtomicAndReplayNeverRestoresRevokedAccount() async throws {
        let account = authorityTestAccount()
        let grant = try await grantAuthority(account, id: 60_010)
        let first = try await deliveredAuthority(grant.handle)
        XCTAssertEqual(first.state["ethereum"] as? [String: String], ["address": account.normalizedAddress, "chainId": "0x1"])
        guard case .snapshot(let current) = await bridge.configurationSnapshot(configurationKey: grant.request.configurationKey, profileIdentifier: nil),
              case .revoked(let revoked) = await bridge.revoke(configurationKey: grant.request.configurationKey,
                provider: .ethereum, attempt: attempt(for: 60_011), expected: current.version, profileIdentifier: nil) else {
            return XCTFail("Expected native revocation")
        }
        XCTAssertNil(revoked.ethereumAccount)
        XCTAssertGreaterThan(revoked.version.revisions.ethereum, current.version.revisions.ethereum)
        let replay = try await deliveredAuthority(grant.handle)
        XCTAssertEqual((replay.state["ethereum"] as? [String: String])?["address"], "")
        XCTAssertEqual(replay.response["result"] as? [String], [account.normalizedAddress])
        guard case .revoked(let repeated) = await bridge.revoke(configurationKey: grant.request.configurationKey,
            provider: .ethereum, attempt: attempt(for: 60_011), expected: current.version, profileIdentifier: nil) else {
            return XCTFail("Expected replayed revocation")
        }
        XCTAssertEqual(repeated.version, revoked.version)
    }

    @MainActor
    func testRevocationAbortsClaimBeforeSignatureCommitButRetainsBroadcastCheckpoint() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 60_020)
        let first = try await admittedSigning(account, id: 60_021)
        let firstClaim = try approvalClaim(await bridge.claim(handle: first.handle))
        XCTAssertEqual(firstClaim.executionDeadline, clock.now.addingTimeInterval(150))
        let firstPermit = try await reviewedExecution(firstClaim)
        let broadcast = try await admittedBroadcast(account, id: 60_022)
        let broadcastClaim = try approvalClaim(await bridge.claim(handle: broadcast.handle))
        let broadcastPermit = try await reviewedExecution(broadcastClaim)
        _ = broadcastPermit.recoveryResponse
        let checkpoint = await prepareReviewedBroadcast(broadcastPermit, in: bridge)
        XCTAssertEqual(checkpoint, .persisted)
        guard case .snapshot(let current) = await bridge.configurationSnapshot(configurationKey: first.request.configurationKey, profileIdentifier: nil),
              case .revoked = await bridge.revoke(configurationKey: first.request.configurationKey,
                provider: .ethereum, attempt: attempt(for: 60_023), expected: current.version, profileIdentifier: nil) else {
            return XCTFail("Expected revocation")
        }
        let isCurrent = await bridge.authorityIsCurrent(handle: first.handle)
        XCTAssertFalse(isCurrent)
        _ = await completeReviewedExecution(firstPermit, in: bridge)
        let firstDelivery = try await deliveredAuthority(first.handle)
        XCTAssertEqual((firstDelivery.response["error"] as? [String: Any])?["code"] as? Int, 4100)
        let completed = await completeReviewedExecution(broadcastPermit, in: bridge)
        XCTAssertEqual(completed, .persisted)
        let broadcastDelivery = try await deliveredAuthority(broadcast.handle)
        XCTAssertEqual(broadcastDelivery.response["approvalCommitted"] as? Bool, true)
        XCTAssertEqual((broadcastDelivery.state["ethereum"] as? [String: String])?["address"], "")
    }

    @MainActor
    func testSameChainSwitchPreservesSigningClaimButChangedChainInvalidatesIt() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 60_100)
        let signing = try await admittedSigning(account, id: 60_101)
        let claim = try approvalClaim(await bridge.claim(handle: signing.handle))
        XCTAssertTrue(claim.adoptForExecution())
        guard case .snapshot(let original) = await bridge.configurationSnapshot(
            configurationKey: signing.request.configurationKey, profileIdentifier: nil
        ) else { return XCTFail("Expected original authority") }
        let admission = DappRequestAdmission(store: bridge, requestProcessor: DappRequestProcessor())

        for (id, chainId) in [(60_102, "0x1"), (60_103, "0xa")] {
            let template = try makeFixture(id: id, name: "switchEthereumChain")
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: template.ingress.canonicalData) as? [String: Any])
            raw["body"] = ["address": account.normalizedAddress, "chainId": chainId,
                           "object": ["chainId": chainId]]
            let switching = try authorityFixture(raw)
            let enqueued = try accepted(await bridge.enqueue(ingress: switching.ingress, profileIdentifier: nil))
            let handle = enqueued.handle
            let unchanged = chainId == original.ethereumChainId
            XCTAssertEqual(enqueued.approvalRequired, !unchanged)
            let disposition = await admission.materialize(handle: handle)
            XCTAssertEqual(disposition, unchanged ? .responseReady : .approvalRequired)
            if unchanged {
                let replay = try accepted(await bridge.enqueue(ingress: switching.ingress, profileIdentifier: nil))
                XCTAssertEqual(replay.handle, handle)
                XCTAssertEqual(replay.admissionKind, .replay)
                XCTAssertFalse(replay.approvalRequired)
            } else {
                let completion = await bridge.completeImmediate(handle: handle, resolution: .ethereumChain(chainId))
                XCTAssertEqual(completion, .persisted)
            }
            let delivery = try await deliveredAuthority(handle)
            XCTAssertTrue(delivery.response["result"] is NSNull)
            guard case .snapshot(let current) = await bridge.configurationSnapshot(
                configurationKey: signing.request.configurationKey, profileIdentifier: nil
            ), case .found(let storedSigning) = await bridge.load(handle: signing.handle) else {
                return XCTFail("Expected readable requests and authority")
            }
            let authorityCurrent = await bridge.authorityIsCurrent(handle: signing.handle)
            XCTAssertEqual(authorityCurrent, unchanged)
            XCTAssertEqual(storedSigning.phase, unchanged ? .approving : .responded)
            XCTAssertEqual(current.ethereumChainId, chainId)
            if unchanged {
                XCTAssertEqual(current.version, original.version)
            } else {
                XCTAssertGreaterThan(current.version.revisions.ethereum, original.version.revisions.ethereum)
            }
        }
        _ = await bridge.complete(claim: claim, resolution: immediateResolution(for: signing.request))
        let signingDelivery = try await deliveredAuthority(signing.handle)
        XCTAssertEqual((signingDelivery.response["error"] as? [String: Any])?["code"] as? Int, 4100)
    }

    func testUnpinnedConnectionsSurviveUnrelatedPermissionChanges() async throws {
        let ethereum = try makeFixture(id: 60_115, name: "requestAccounts", host: "new.example")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: ethereum.ingress.canonicalData) as? [String: Any])
        raw["id"] = 60_116
        raw["enqueueAttempt"] = attempt(for: 60_116)
        raw["provider"] = "solana"
        raw["name"] = "connect"
        raw["body"] = ["publicKey": "", "object": [:]]
        let solana = try authorityFixture(raw)

        _ = try await grantAuthority(authorityTestAccount(), id: 60_117)
        let other = try await removalSnapshot()
        guard case .revoked = await bridge.revoke(
            configurationKey: "https://wallet.example", provider: .ethereum,
            attempt: attempt(for: 60_118), expected: other.version, profileIdentifier: nil
        ) else { return XCTFail("Expected unrelated revocation") }

        bridge = makeBridge(clock: { [clock = clock!] in clock.now })
        let current = try await removalSnapshot(host: "new.example")
        XCTAssertEqual(current.version, ethereum.ingress.authority)
        XCTAssertNil((try storedProfile()["origins"] as? [String: Any])?["https://new.example"])
        for fixture in [ethereum, solana] {
            let admission = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil))
            XCTAssertTrue(admission.approvalRequired)
            let authorityCurrent = await bridge.authorityIsCurrent(handle: admission.handle)
            XCTAssertTrue(authorityCurrent)
        }
    }

    func testECRecoverSurvivesUnrelatedWatermarkAndLocalGrantChanges() async throws {
        let now = clock.now
        clock.now.addTimeInterval(-3_601)
        guard case .snapshot(let other) = await bridge.configurationSnapshot(
            configurationKey: "https://other.example", profileIdentifier: nil
        ), case .revoked = await bridge.revoke(configurationKey: "https://other.example", provider: .ethereum,
            attempt: attempt(for: 60_112), expected: other.version, profileIdentifier: nil)
        else { return XCTFail("Expected unrelated revocation") }
        clock.now = now
        let first = try makeFixture(id: 60_110)
        let second = try makeFixture(id: 60_111)
        await bridge.performMaintenance(profileIdentifier: nil)
        guard case .snapshot(let advanced) = await bridge.configurationSnapshot(
            configurationKey: first.request.configurationKey, profileIdentifier: nil
        ) else { return XCTFail("Expected unrelated authority advance") }
        XCTAssertGreaterThan(advanced.version.revisions.ethereum, first.ingress.authority.revisions.ethereum)
        let firstHandle = try accepted(await bridge.enqueue(ingress: first.ingress, profileIdentifier: nil)).handle
        let secondHandle = try accepted(await bridge.enqueue(ingress: second.ingress, profileIdentifier: nil)).handle
        let firstClaim = try approvalClaim(await bridge.claim(handle: firstHandle))
        XCTAssertTrue(firstClaim.adoptForExecution())

        let grant = try await grantAuthority(authorityTestAccount(), id: 60_113)
        let secondClaim = try approvalClaim(await bridge.claim(handle: secondHandle))
        XCTAssertTrue(secondClaim.adoptForExecution())
        guard case .snapshot(let granted) = await bridge.configurationSnapshot(
            configurationKey: grant.request.configurationKey, profileIdentifier: nil
        ), case .revoked = await bridge.revoke(configurationKey: grant.request.configurationKey, provider: .ethereum,
            attempt: attempt(for: 60_114), expected: granted.version, profileIdentifier: nil) else {
            return XCTFail("Expected local grant revocation")
        }
        for (fixture, handle, permit) in [(first, firstHandle, firstClaim), (second, secondHandle, secondClaim)] {
            let authorityCurrent = await bridge.authorityIsCurrent(handle: handle)
            XCTAssertTrue(authorityCurrent)
            let completion = await bridge.complete(claim: permit, resolution: immediateResolution(for: fixture.request))
            XCTAssertEqual(completion, .persisted)
            let delivery = try await deliveredAuthority(handle)
            XCTAssertEqual(delivery.response["kind"] as? String, "result")
        }
    }

    func testECRecoverStillRejectsForeignOriginAndProfileContexts() async throws {
        let fixture = try makeFixture(id: 60_120)
        guard case .snapshot(let other) = await bridge.configurationSnapshot(
            configurationKey: "https://other.example", profileIdentifier: nil
        ) else { return XCTFail("Expected other origin authority") }
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.ingress.canonicalData) as? [String: Any])
        raw["authority"] = other.version.json
        let wrongOrigin = try authorityFixture(raw)
        guard case .unauthorized = await bridge.enqueue(ingress: wrongOrigin.ingress, profileIdentifier: nil),
              case .unauthorized = await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: UUID()) else {
            return XCTFail("Permission-free requests must retain origin and profile binding")
        }
    }

    func testNativeClaimExecutesWithoutWorkerAndExpiresOnNativeDeadline() async throws {
        let fixture = try makeFixture(id: 60_030, name: "requestAccounts")
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let delivered = try await recordNativeDelivery(handle: handle)
        XCTAssertEqual(delivered, .persisted)
        let claim = await claimDeliveredNativeExecution(in: bridge, handle: handle, approvedAt: clock.now)
        guard case .claimed(let nativeClaim) = claim else { return XCTFail("Native approval must execute directly") }
        XCTAssertEqual(nativeClaim.executionDeadline, clock.now.addingTimeInterval(150))
        let competing = await claimDeliveredNativeExecution(in: bridge, handle: handle, approvedAt: clock.now)
        XCTAssertEqual(competing, .executing)
        XCTAssertTrue(nativeClaim.adoptForExecution())
        clock.now = nativeClaim.executionDeadline
        let expiredCompletion = await bridge.complete(claim: nativeClaim, resolution: immediateResolution(for: fixture.request))
        XCTAssertEqual(expiredCompletion, .ownershipLost)
        nativeClaim.releaseUnapproved()
    }

    func testNativeClaimCannotReviveApprovalAfterAuthorityRevocation() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 60_032)
        let signing = try await admittedSigning(account, id: 60_033)
        _ = try await recordNativeDelivery(handle: signing.handle)
        let approvedAt = clock.now
        guard case .found(let delivered) = await bridge.load(handle: signing.handle),
              let receipt = delivered.nativeDeliveryReceipt,
              case .snapshot(let current) = await bridge.configurationSnapshot(
                configurationKey: signing.request.configurationKey, profileIdentifier: nil
              ), case .revoked = await bridge.revoke(
                configurationKey: signing.request.configurationKey, provider: .ethereum,
                attempt: attempt(for: 60_034), expected: current.version, profileIdentifier: nil
              ) else { return XCTFail("Expected revocation after delivery") }
        let consent = try await Self.reviewedConsent(delivered, approvedAt: approvedAt, nativeReceipt: receipt)
        let result = await bridge.claimNativeExecution(consent: consent)
        XCTAssertEqual(result, .responded)
        let response = try await deliveredAuthority(signing.handle)
        XCTAssertEqual((response.response["error"] as? [String: Any])?["code"] as? Int, 4100)
    }

    @MainActor
    func testPreviousPermitCannotCommitANewerNativeClaim() async throws {
        let fixture = try makeTransactionFixture(id: 60_035)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let originalClaim = try approvalClaim(await bridge.claim(handle: handle))
        let originalPermit = try await reviewedExecution(originalClaim)
        let rollback = await bridge.abandon(permit: originalPermit.permit)
        XCTAssertEqual(rollback, .persisted)

        let delivered = try await recordNativeDelivery(handle: handle)
        XCTAssertEqual(delivered, .persisted)
        guard case .claimed(let currentClaim) = await claimDeliveredNativeExecution(
            in: bridge, handle: handle, approvedAt: clock.now
        ) else { return XCTFail("Expected native claim") }
        let currentPermit = try await reviewedExecution(currentClaim)
        defer { currentPermit.releaseLease() }
        let staleCheckpoint = await prepareReviewedBroadcast(originalPermit, in: bridge)
        let staleCompletion = await completeReviewedExecution(originalPermit, in: bridge)
        XCTAssertEqual(staleCheckpoint, .ownershipLost)
        XCTAssertEqual(staleCompletion, .ownershipLost)
        guard case .found(let current) = await bridge.load(handle: handle) else {
            return XCTFail("Expected current claim to survive stale commits")
        }
        XCTAssertEqual(current.nativeExecutionContext, try nativeApproval(currentClaim).context)
        XCTAssertTrue(current.hasActiveExecution)
        let checkpoint = await prepareReviewedBroadcast(currentPermit, in: bridge)
        XCTAssertEqual(checkpoint, .persisted)
        let completion = await completeReviewedExecution(currentPermit, in: bridge)
        XCTAssertEqual(completion, .persisted)
    }

    func testConcurrentNativeClaimersPersistOnlyOneAtomicTransition() async throws {
        let fixture = try makeFixture(id: 60_031, name: "requestAccounts")
        let admission = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil))
        let owner = storedRequestNativeOwner()
        let delivered = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle, nativeDeliveryNonce: admission.nativeDeliveryNonce, owner: owner
        )
        XCTAssertEqual(delivered, .persisted)
        let now = clock.now
        let writes = LockedTestValue(0)
        let atomicWrite: @Sendable (Data, URL) throws -> Void = { data, url in
            writes.withValue { $0 += 1 }
            let profile = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any])
            let records = try XCTUnwrap(profile["records"] as? [[String: Any]])
            let state = try XCTUnwrap(records.first?["state"] as? [String: Any])
            XCTAssertEqual(Set(state.keys), ["claimed"])
            try ApprovalStoreTestPersistence.write(data, url)
        }
        let first = makeBridge(clock: { now }, atomicWrite: atomicWrite)
        let second = makeBridge(clock: { now }, atomicWrite: atomicWrite)
        let consent = try await nativeConsent(handle: admission.handle, approvedAt: now)
        async let firstResult = first.claimNativeExecution(consent: consent)
        async let secondResult = second.claimNativeExecution(consent: consent)
        let results = await [firstResult, secondResult]
        let claims = results.compactMap { result -> ExtensionBridge.ApprovalClaim? in
            guard case .claimed(let claim) = result else { return nil }
            return claim
        }
        defer { claims.forEach { $0.releaseUnapproved() } }
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(results.filter { $0 == .executing }.count, 1)
        XCTAssertEqual(writes.value, 1)
        guard case .found(let snapshot) = await bridge.load(handle: admission.handle) else {
            return XCTFail("Expected persisted execution")
        }
        XCTAssertTrue(snapshot.hasActiveExecution)
        XCTAssertFalse(snapshot.isQueuedForNativeApproval)
        XCTAssertEqual(snapshot.nativeApproval?.approvedAt, now)
        XCTAssertEqual(snapshot.nativeExecutionContext, try claims.first.map { try nativeApproval($0).context })
    }

    @MainActor
    func testReturnToReviewRequiresFreshConsentAndPreservesRequestIdentity() async throws {
        for native in [false, true] {
            let fixture = try makeTransactionFixture(id: native ? 60_052 : 60_051)
            let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
            if native { _ = try await recordNativeDelivery(handle: handle) }
            guard case .found(let original) = await bridge.load(handle: handle) else {
                return XCTFail("Expected original review")
            }
            let consent = try Self.reviewedConsent(original, approvedAt: clock.now)
            let claim: ExtensionBridge.ApprovalClaim
            if native {
                guard case .claimed(let value) = await bridge.claimNativeExecution(consent: consent) else {
                    return XCTFail("Expected native claim")
                }
                claim = value
            } else {
                claim = try approvalClaim(await bridge.claim(handle: handle))
            }
            XCTAssertTrue(claim.adoptForExecution())
            let oldApproval = try consent.resolve(context: approvalResolutionContextForTesting(
                action: consent.intent.action, decision: consent.decision
            )).get()
            let returned = await bridge.returnToReview(claim: claim, consent: consent)
            XCTAssertEqual(returned, .persisted)
            XCTAssertFalse(consent.authorizationIsAvailable)
            XCTAssertFalse(claim.adoptForExecution())
            XCTAssertFalse(FileManager.default.fileExists(atPath: operationLockURL(handle).path))
            guard case .found(let pending) = await bridge.load(handle: handle),
                  case .queued = pending.state else { return XCTFail("Expected a fresh pending review") }
            XCTAssertEqual(pending.requestBinding, original.requestBinding)
            XCTAssertEqual(pending.nativeDeliveryReceipt, original.nativeDeliveryReceipt)
            XCTAssertEqual(pending.nativeDeliveryNonce, original.nativeDeliveryNonce)
            XCTAssertEqual(pending.createdAt, original.createdAt)
            XCTAssertEqual(pending.request?.admissionDeadline, original.request?.admissionDeadline)
            XCTAssertNil(pending.nativeApproval)
            XCTAssertNil(pending.nativeExecutionContext)
            let stored = try Data(contentsOf: defaultProfileURL)
            if native {
                let writer = try XCTUnwrap(bridge)
                async let first = writer.claimNativeExecution(consent: consent)
                async let second = writer.claimNativeExecution(consent: consent)
                let repeated = await [first, second]
                XCTAssertEqual(repeated, [.reviewRequired, .reviewRequired])
                XCTAssertEqual(try Data(contentsOf: defaultProfileURL), stored)
            }
            let freshConsent = try Self.reviewedConsent(pending, approvedAt: consent.approvedAt)
            XCTAssertFalse(freshConsent.sharesAuthorization(with: consent))
            let freshClaim: ExtensionBridge.ApprovalClaim
            if native {
                guard case .claimed(let value) = await bridge.claimNativeExecution(consent: freshConsent) else {
                    return XCTFail("Expected a fresh native claim")
                }
                freshClaim = value
            } else {
                freshClaim = try approvalClaim(await bridge.claim(handle: handle))
            }
            XCTAssertTrue(freshClaim.adoptForExecution())
            let staleAuthorization = await bridge.authorize(claim: freshClaim, approval: oldApproval)
            XCTAssertEqual(staleAuthorization, .ownershipLost)
            XCTAssertTrue(freshConsent.authorizationIsAvailable)
            let freshApproval = try freshConsent.resolve(context: approvalResolutionContextForTesting(
                action: freshConsent.intent.action, decision: freshConsent.decision
            )).get()
            guard case .authorized(let permit) = await bridge.authorize(claim: freshClaim, approval: freshApproval) else {
                return XCTFail("The fresh consent must still authorize")
            }
            let abandoned = await bridge.abandon(permit: permit)
            XCTAssertEqual(abandoned, .persisted)
            if !native { _ = await bridge.reject(handle: handle) }
        }
    }

    @MainActor
    func testNativeReviewRetryFencesConcurrentOldClaimsAndReplacementConsent() async throws {
        let fixture = try makeTransactionFixture(id: 60_053)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        _ = try await recordNativeDelivery(handle: handle)
        guard case .found(let snapshot) = await bridge.load(handle: handle) else {
            return XCTFail("Expected native request")
        }
        let consent = try Self.reviewedConsent(snapshot, approvedAt: clock.now)
        let replacement = try Self.reviewedConsent(snapshot, approvedAt: clock.now)
        guard case .claimed(let claim) = await bridge.claimNativeExecution(consent: consent) else {
            return XCTFail("Expected native claim")
        }
        XCTAssertTrue(claim.adoptForExecution())
        let originalData = try Data(contentsOf: defaultProfileURL)
        let mismatchedReturn = await bridge.returnToReview(claim: claim, consent: replacement)
        XCTAssertEqual(mismatchedReturn, .ownershipLost)
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), originalData)
        XCTAssertTrue(consent.authorizationIsAvailable)
        let replacementApproval = try replacement.resolve(context: approvalResolutionContextForTesting(
            action: replacement.intent.action, decision: replacement.decision
        )).get()
        let mismatchedAuthorization = await bridge.authorize(claim: claim, approval: replacementApproval)
        XCTAssertEqual(mismatchedAuthorization, .ownershipLost)
        XCTAssertTrue(replacement.authorizationIsAvailable)
        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        let writer = try XCTUnwrap(bridge)
        async let returning = writer.returnToReview(claim: claim, consent: consent)
        async let first = observer.claimNativeExecution(consent: consent)
        async let second = observer.claimNativeExecution(consent: consent)
        let returned = await returning
        let attempts = await [first, second]
        XCTAssertEqual(returned, .persisted)
        XCTAssertTrue(attempts.allSatisfy { $0 == .executing || $0 == .reviewRequired })
        let replay = await observer.claimNativeExecution(consent: consent)
        XCTAssertEqual(replay, .reviewRequired)
        guard case .found(let pending) = await bridge.load(handle: handle),
              case .queued(_, .delivered) = pending.state else {
            return XCTFail("Old attempts must leave the new review pending")
        }
        XCTAssertEqual(pending.nativeDeliveryReceipt, snapshot.nativeDeliveryReceipt)
    }

    @MainActor
    func testReturnToReviewCannotUndoAuthorizationExecutionBroadcastOrCompletion() async throws {
        for (index, stage) in ["unadopted", "authorized", "executing", "broadcast", "completed"].enumerated() {
            let fixture = try makeTransactionFixture(id: 60_060 + index)
            let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
            _ = try await recordNativeDelivery(handle: handle)
            guard case .found(let snapshot) = await bridge.load(handle: handle) else { return XCTFail("Expected request") }
            let consent = try Self.reviewedConsent(snapshot, approvedAt: clock.now)
            guard case .claimed(let claim) = await bridge.claimNativeExecution(consent: consent) else {
                return XCTFail("Expected claim")
            }
            var retainedPermit: ExtensionBridge.ApprovedExecutionPermit?
            if stage != "unadopted" {
                XCTAssertTrue(claim.adoptForExecution())
                let approval = try consent.resolve(context: approvalResolutionContextForTesting(
                    action: consent.intent.action, decision: consent.decision
                )).get()
                guard case .authorized(let permit) = await bridge.authorize(claim: claim, approval: approval) else {
                    return XCTFail("Expected permit")
                }
                retainedPermit = permit
                if stage != "authorized" { XCTAssertTrue(permit.consumeExecution()) }
                if stage == "broadcast" {
                    let broadcast = try await preparedBroadcastForTesting(permit: permit, clock: { [clock = clock!] in clock.now })
                    guard case .prepared = await bridge.prepareBroadcast(permit: permit, broadcast: broadcast) else {
                        return XCTFail("Expected broadcast checkpoint")
                    }
                } else if stage == "completed" {
                    let completion = try XCTUnwrap(ApprovedCompletion.failure(.userRejected, permit: permit))
                    let completed = await bridge.complete(permit: permit, result: completion)
                    XCTAssertEqual(completed, .persisted)
                }
            }
            let before = try Data(contentsOf: defaultProfileURL)
            let returned = await bridge.returnToReview(claim: claim, consent: consent)
            XCTAssertEqual(returned, .ownershipLost, stage)
            XCTAssertEqual(try Data(contentsOf: defaultProfileURL), before, stage)
            retainedPermit?.releaseLease()
            claim.releaseUnapproved()
            await bridge.performMaintenance(profileIdentifier: nil)
        }
    }

    @MainActor
    func testReturnToReviewCannotExtendDeadlineOrUndoRevocation() async throws {
        for revoked in [false, true] {
            let fixture = try makeTransactionFixture(id: revoked ? 60_071 : 60_070)
            let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
            _ = try await recordNativeDelivery(handle: handle)
            guard case .found(let snapshot) = await bridge.load(handle: handle) else { return XCTFail("Expected request") }
            let consent = try Self.reviewedConsent(snapshot, approvedAt: clock.now)
            guard case .claimed(let claim) = await bridge.claimNativeExecution(consent: consent) else {
                return XCTFail("Expected claim")
            }
            XCTAssertTrue(claim.adoptForExecution())
            if revoked {
                try removalStore().withRevokedWalletAuthority(matching: .wallet(id: authorityTestAccount().walletID)) {}
            } else {
                clock.now = claim.executionDeadline
            }
            let returned = await bridge.returnToReview(claim: claim, consent: consent)
            XCTAssertEqual(returned, .ownershipLost)
            claim.releaseUnapproved()
            guard case .found(let terminal) = await bridge.load(handle: handle) else { return XCTFail("Expected retained response") }
            XCTAssertEqual(terminal.phase, .responded)
            XCTAssertNil(terminal.nativeDeliveryReceipt)
        }
    }

    @MainActor
    func testReturnToReviewConfirmsDurablePublicationBeforeReleasingLease() async throws {
        for (index, mode) in ["beforeWrite", "afterWrite", "failedSync"].enumerated() {
            let fixture = try makeTransactionFixture(id: 60_080 + index)
            let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
            _ = try await recordNativeDelivery(handle: handle)
            guard case .found(let snapshot) = await bridge.load(handle: handle) else { return XCTFail("Expected request") }
            let consent = try Self.reviewedConsent(snapshot, approvedAt: clock.now)
            guard case .claimed(let claim) = await bridge.claimNativeExecution(consent: consent) else {
                return XCTFail("Expected native claim")
            }
            XCTAssertTrue(claim.adoptForExecution())
            let lockURL = operationLockURL(handle)
            let synchronizations = LockedTestValue(0)
            let writer = makeBridge(
                clock: { [clock = clock!] in clock.now },
                atomicWrite: { data, url in
                    XCTAssertFalse(consent.authorizationIsAvailable)
                    let contender = CrossProcessFileLock(fileURL: lockURL)
                    XCTAssertFalse(try contender.tryAcquireExisting())
                    if mode != "beforeWrite" { try ApprovalStoreTestPersistence.write(data, url) }
                    throw Failure.injectedWrite
                },
                synchronizePublishedFile: { url in
                    synchronizations.withValue { $0 += 1 }
                    let contender = CrossProcessFileLock(fileURL: lockURL)
                    XCTAssertFalse(try contender.tryAcquireExisting())
                    if mode == "failedSync" { throw Failure.injectedWrite }
                    try ApprovalStoreTestPersistence.synchronize(url)
                }
            )
            let returned = await writer.returnToReview(claim: claim, consent: consent)
            XCTAssertEqual(returned, mode == "afterWrite" ? .persisted : .retryablePersistenceFailure, mode)
            XCTAssertEqual(synchronizations.value, mode == "beforeWrite" ? 0 : 1, mode)
            XCTAssertFalse(consent.authorizationIsAvailable)
            if mode == "afterWrite" {
                XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
                guard case .found(let pending) = await bridge.load(handle: handle),
                      case .queued(_, .delivered) = pending.state else {
                    return XCTFail("Durable read-back must preserve a fresh review")
                }
            } else {
                let contender = CrossProcessFileLock(fileURL: lockURL)
                XCTAssertFalse(try contender.tryAcquireExisting())
                claim.releaseUnapproved()
                let receipt = try XCTUnwrap(snapshot.nativeDeliveryReceipt)
                _ = await bridge.interruptNativeApproval(
                    handle: handle, nativeDeliveryNonce: receipt.nativeDeliveryNonce,
                    runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier
                )
            }
        }
    }

    func testDisconnectedReclamationAdvancesWatermarkAndPreservesProfileEpoch() async throws {
        let fixture = try makeFixture(id: 60_040)
        let origin = fixture.request.configurationKey
        let before = fixture.ingress.authority
        guard case .revoked(let revoked) = await bridge.revoke(configurationKey: origin, provider: .ethereum,
            attempt: attempt(for: 60_041), expected: before, profileIdentifier: nil) else { return XCTFail("Expected revoke") }
        clock.now.addTimeInterval(3_601)
        await bridge.performMaintenance(profileIdentifier: nil)
        guard case .snapshot(let absent) = await bridge.configurationSnapshot(configurationKey: origin, profileIdentifier: nil) else {
            return XCTFail("Expected absent-origin authority")
        }
        XCTAssertEqual(absent.version.context, before.context)
        XCTAssertGreaterThan(absent.version.revisions.ethereum, revoked.version.revisions.ethereum)
        XCTAssertEqual((try storedProfile()["origins"] as? [String: Any])?.count, 0)
        let template = try makeFixture(id: 60_042, name: "requestAccounts")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: template.ingress.canonicalData) as? [String: Any])
        raw["authority"] = before.json
        let stale = try authorityFixture(raw)
        guard case .unauthorized = await bridge.enqueue(ingress: stale.ingress, profileIdentifier: nil) else {
            return XCTFail("Reclamation must not revive an old connection intent")
        }
        guard case .stale = await bridge.revoke(configurationKey: origin, provider: .ethereum,
            attempt: attempt(for: 60_041), expected: before, profileIdentifier: nil) else {
            return XCTFail("An expired receipt cannot make an old revoke fresh again")
        }
    }

    func testPinnedOriginDoesNotDriftWhenOtherOriginAdvancesWatermark() async throws {
        let fixture = try makeFixture(id: 60_050, name: "requestAccounts")
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        guard case .snapshot(let other) = await bridge.configurationSnapshot(configurationKey: "https://other.example", profileIdentifier: nil),
              case .revoked = await bridge.revoke(configurationKey: "https://other.example", provider: .solana,
                attempt: attempt(for: 60_051), expected: other.version, profileIdentifier: nil) else {
            return XCTFail("Expected unrelated revocation")
        }
        let authorityCurrent = await bridge.authorityIsCurrent(handle: handle)
        XCTAssertTrue(authorityCurrent)
        let pinnedClaim = try approvalClaim(await bridge.claim(handle: handle))
        XCTAssertEqual(pinnedClaim.executionDeadline, clock.now.addingTimeInterval(150))
    }

    func testOriginCapacityEvictsUnusedChainPreferencesWithoutRevokingProtectedOrigins() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 62_000)
        clock.now.addTimeInterval(3_601)
        await bridge.performMaintenance(profileIdentifier: nil)
        let pending = try makeFixture(id: 62_001, name: "requestAccounts", host: "pending.example")
        let pendingHandle = try accepted(await bridge.enqueue(ingress: pending.ingress, profileIdentifier: nil)).handle
        guard case .snapshot(let receiptAuthority) = await bridge.configurationSnapshot(
            configurationKey: "https://receipt.example", profileIdentifier: nil
        ), case .revoked = await bridge.revoke(
            configurationKey: "https://receipt.example", provider: .ethereum,
            attempt: attempt(for: 62_002), expected: receiptAuthority.version, profileIdentifier: nil
        ) else { return XCTFail("Expected retained revocation receipt") }

        var profile = try storedProfile()
        var origins = try XCTUnwrap(profile["origins"] as? [String: Any])
        let sequence = try XCTUnwrap(profile["authoritySequence"] as? Int)
        let unused: [String: Any] = [
            "ethereumChainId": "0xa", "revisions": ["ethereum": sequence, "solana": sequence],
        ]
        for index in 0..<(512 - origins.count) { origins["https://z\(index).example"] = unused }
        profile["origins"] = origins
        try PropertyListSerialization.data(fromPropertyList: profile, format: .binary, options: 0)
            .write(to: defaultProfileURL, options: .atomic)
        let evictedVersion = try authorityVersion("https://z0.example")
        let incoming = try makeFixture(id: 62_003, name: "requestAccounts", host: "new.example")
        let admitted = try accepted(await bridge.enqueue(ingress: incoming.ingress, profileIdentifier: nil))
        XCTAssertEqual(admitted.revisions, incoming.ingress.authority.revisions)
        let claim = try approvalClaim(await bridge.claim(handle: admitted.handle))
        let released = await bridge.abandon(claim: claim)
        XCTAssertEqual(released, .persisted)

        let retained = try XCTUnwrap(try storedProfile()["origins"] as? [String: Any])
        XCTAssertEqual(retained.count, 512)
        XCTAssertNil(retained["https://z0.example"])
        XCTAssertNotNil(retained["https://pending.example"])
        XCTAssertNotNil(retained["https://receipt.example"])
        guard case .snapshot(let connected) = await bridge.configurationSnapshot(
            configurationKey: "https://wallet.example", profileIdentifier: nil
        ), case .found = await bridge.load(handle: pendingHandle),
           case .stale(let evicted) = await bridge.revoke(
            configurationKey: "https://z0.example", provider: .ethereum,
            attempt: attempt(for: 62_004), expected: evictedVersion, profileIdentifier: nil
        ) else { return XCTFail("Protected origins must survive and evicted authority must be stale") }
        XCTAssertEqual(connected.ethereumAccount, account)
        XCTAssertEqual(evicted.ethereumChainId, "0x1")
        XCTAssertEqual(evicted.version.context, evictedVersion.context)
        XCTAssertGreaterThan(evicted.version.revisions.ethereum, evictedVersion.revisions.ethereum)
    }

    func testAdmissionRejectsPayloadThatExceedsLimitAfterAuthorityBinding() async throws {
        let pinned = try makeFixture(id: 60_060)
        let pinnedHandle = try accepted(await bridge.enqueue(ingress: pinned.ingress, profileIdentifier: nil)).handle
        guard case .snapshot(var current) = await bridge.configurationSnapshot(
            configurationKey: pinned.request.configurationKey, profileIdentifier: nil
        ) else { return XCTFail("Expected authority") }
        for id in 60_061...60_069 {
            guard case .revoked(let next) = await bridge.revoke(
                configurationKey: pinned.request.configurationKey, provider: .solana,
                attempt: attempt(for: id), expected: current.version, profileIdentifier: nil
            ) else { return XCTFail("Expected Solana revision to advance") }
            current = next
        }
        XCTAssertEqual(current.version.revisions.solana, 9)
        let template = try makeFixture(id: 60_070)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: template.ingress.canonicalData) as? [String: Any])
        raw["name"] = "requestAccounts"
        raw["body"] = ["address": "", "object": ["padding": ""]]
        let emptySize = try XCTUnwrap(ExtensionBridge.payloadData(raw, options: [.sortedKeys])).count
        let paddingCount = ExtensionBridge.maximumPayloadBytes - emptySize
        raw["body"] = ["address": "", "object": ["padding": String(repeating: "x", count: paddingCount)]]
        let oversizedAfterBinding = try authorityFixture(raw)
        XCTAssertEqual(oversizedAfterBinding.ingress.canonicalData.count, ExtensionBridge.maximumPayloadBytes)
        guard case .revoked(let advanced) = await bridge.revoke(
            configurationKey: pinned.request.configurationKey, provider: .solana,
            attempt: attempt(for: 60_071), expected: current.version, profileIdentifier: nil
        ) else { return XCTFail("Expected Solana revision to gain a digit") }
        XCTAssertEqual(advanced.version.revisions.ethereum, current.version.revisions.ethereum)
        XCTAssertEqual(advanced.version.revisions.solana, 10)
        var boundRaw = raw
        boundRaw["authority"] = advanced.version.json
        XCTAssertEqual(try XCTUnwrap(ExtensionBridge.payloadData(boundRaw, options: [.sortedKeys])).count,
                       ExtensionBridge.maximumPayloadBytes + 1)
        let original = try Data(contentsOf: defaultProfileURL)
        let rejectingWriter = makeBridge(clock: { [clock = clock!] in clock.now }, atomicWrite: { _, _ in
            XCTFail("Oversized bound requests must not write the profile")
            throw Failure.injectedWrite
        })
        guard case .rejected = await rejectingWriter.enqueue(
            ingress: oversizedAfterBinding.ingress, profileIdentifier: nil
        ) else { return XCTFail("Expected oversized bound payload to be rejected") }
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original)
        guard case .snapshot(let readable) = await bridge.configurationSnapshot(
            configurationKey: pinned.request.configurationKey, profileIdentifier: nil
        ), case .found = await bridge.load(handle: pinnedHandle) else {
            return XCTFail("Rejected admission must preserve the readable profile")
        }
        XCTAssertEqual(readable.version, advanced.version)

        raw["body"] = ["address": "", "object": ["padding": String(repeating: "x", count: paddingCount - 1)]]
        let exactlyAtLimitAfterBinding = try authorityFixture(raw)
        let admitted = try accepted(await bridge.enqueue(
            ingress: exactlyAtLimitAfterBinding.ingress, profileIdentifier: nil
        ))
        guard case .found(let snapshot) = await bridge.load(handle: admitted.handle) else {
            return XCTFail("A bound payload exactly at the limit must remain readable")
        }
        XCTAssertEqual(snapshot.request?.authority, advanced.version)
    }

    func testNativeClaimExpiresWhenProfileReadCrossesAdmissionDeadline() async throws {
        let callbackClock = clock!
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 60_080)
        let fixture = try makeTransactionFixture(id: 60_081, admissionDeadline: clock.now.addingTimeInterval(1))
        let admission = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil))
        let owner = storedRequestNativeOwner()
        let receipt = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle, nativeDeliveryNonce: admission.nativeDeliveryNonce, owner: owner
        )
        XCTAssertEqual(receipt, .persisted)
        clock.now = fixture.request.admissionDeadline.addingTimeInterval(-0.01)
        let approvedAt = clock.now
        let consent = try await nativeConsent(handle: admission.handle, approvedAt: approvedAt)
        let writes = LockedTestValue(0)
        let claimingWriter = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { data, url in
                writes.withValue { $0 += 1 }
                let profile = try XCTUnwrap(PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil
                ) as? [String: Any])
                let records = try XCTUnwrap(profile["records"] as? [[String: Any]])
                let record = try XCTUnwrap(records.first { $0["id"] as? Int == fixture.request.id })
                let state = try XCTUnwrap(record["state"] as? [String: Any])
                XCTAssertNotNil(state["completed"], "Expiry must be written instead of an invalid execution context")
                try ApprovalStoreTestPersistence.write(data, url)
            },
            readData: { url in
                let data = try Data(contentsOf: url)
                callbackClock.now = fixture.request.admissionDeadline.addingTimeInterval(0.01)
                return data
            }
        )
        let result = await claimingWriter.claimNativeExecution(consent: consent)
        XCTAssertEqual(result, .ownershipLost)
        XCTAssertEqual(writes.value, 1)
        let delivery = try await deliveredAuthority(admission.handle)
        XCTAssertEqual((delivery.response["error"] as? [String: Any])?["code"] as? Int,
                       ProviderResponseError.userRejectedCode)
        guard case .snapshot(let readable) = await bridge.configurationSnapshot(
            configurationKey: fixture.request.configurationKey, profileIdentifier: nil
        ) else { return XCTFail("Expired claiming must preserve the readable profile") }
        XCTAssertEqual(readable.ethereumAccount, account)
    }

    func testBoundedRevocationReceiptsCannotReplayAcrossLaterGrant() async throws {
        let origin = "https://wallet.example"
        guard case .snapshot(let initial) = await bridge.configurationSnapshot(configurationKey: origin, profileIdentifier: nil) else {
            return XCTFail("Expected initial authority")
        }
        var current = initial
        for id in 61_000...61_256 {
            guard case .revoked(let next) = await bridge.revoke(configurationKey: origin, provider: .ethereum,
                attempt: attempt(for: id), expected: current.version, profileIdentifier: nil) else {
                return XCTFail("Expected durable revocation")
            }
            current = next
        }
        XCTAssertEqual((try storedProfile()["mutationReceipts"] as? [Any])?.count, 256)
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 61_300)
        guard case .stale(let unchanged) = await bridge.revoke(configurationKey: origin, provider: .ethereum,
            attempt: attempt(for: 61_000), expected: initial.version, profileIdentifier: nil) else {
            return XCTFail("An evicted receipt must not authorize replay against a newer grant")
        }
        XCTAssertEqual(unchanged.ethereumAccount, account)
    }

    func testRevocationCannotPersistAuthorityBeyondItsReadableByteLimit() async throws {
        struct Origin: Codable {
            var ethereumAccount: WalletAccountDescriptor?
            var ethereumChainId = "0xa"
            var solanaAccount: WalletAccountDescriptor?
            var revisions: ExtensionBridge.ProviderRevisions
        }
        let limit = 1_024 * 1_024
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        func originKey(_ index: Int, length: Int) -> String {
            var key = "file:///tmp/\(index)/"
            while key.utf8.count + 235 < length {
                key += String(repeating: "%E4%B8%AD", count: 26) + "/"
            }
            let remaining = length - key.utf8.count
            return key + String(repeating: "%E4%B8%AD", count: remaining / 9) +
                String(repeating: "b", count: remaining % 9)
        }
        func origin(_ index: Int) throws -> Origin {
            Origin(revisions: try XCTUnwrap(ExtensionBridge.ProviderRevisions(
                rawValue: ["ethereum": index + 1, "solana": index]
            )))
        }
        func maximumLength(budget: Int, makeOrigins: (Int) throws -> [String: Origin]) throws -> Int {
            var lower = 1_000
            var upper = 3_000
            while lower < upper {
                let middle = (lower + upper + 1) / 2
                if try encoder.encode(makeOrigins(middle)).count <= budget { lower = middle }
                else { upper = middle - 1 }
            }
            return lower
        }
        func baseOrigins(length: Int) throws -> [String: Origin] {
            try Dictionary(uniqueKeysWithValues: (0..<399).map {
                (originKey($0, length: length), try origin($0))
            })
        }
        let ordinaryLength = try maximumLength(budget: limit - 2_000, makeOrigins: baseOrigins)
        let base = try baseOrigins(length: ordinaryLength)
        func paddedOrigins(length: Int) throws -> [String: Origin] {
            var origins = base
            origins[originKey(399, length: length)] = try origin(399)
            return origins
        }
        let finalLength = try maximumLength(budget: limit, makeOrigins: paddedOrigins)
        var origins = try paddedOrigins(length: finalLength)
        let key = originKey(0, length: ordinaryLength)
        XCTAssertTrue(origins.keys.allSatisfy {
            guard let url = URL(string: $0) else { return false }
            return $0.utf8.count <= 4_096 && url.absoluteString == $0 &&
                url.path.utf8.count <= 1_024 && url.pathComponents.allSatisfy { $0.utf8.count <= 255 }
        })
        XCTAssertLessThanOrEqual(try encoder.encode(origins).count, limit)
        var revokedOrigins = origins
        revokedOrigins[key]?.revisions = try XCTUnwrap(ExtensionBridge.ProviderRevisions(
            rawValue: ["ethereum": 401, "solana": 0]
        ))
        XCTAssertGreaterThan(try encoder.encode(revokedOrigins).count, limit)

        guard case .snapshot = await bridge.configurationSnapshot(configurationKey: key, profileIdentifier: nil) else {
            return XCTFail("Expected profile bootstrap")
        }
        var profile = try storedProfile()
        profile["authoritySequence"] = 400
        func seed(_ origins: [String: Origin]) throws {
            profile["origins"] = try PropertyListSerialization.propertyList(
                from: encoder.encode(origins), options: [], format: nil
            )
            try PropertyListSerialization.data(fromPropertyList: profile, format: .binary, options: 0)
                .write(to: defaultProfileURL, options: .atomic)
        }
        try seed(origins)
        let original = try Data(contentsOf: defaultProfileURL)
        let writes = LockedTestValue(0)
        let tested = makeBridge(clock: { [clock = clock!] in clock.now }, atomicWrite: { data, url in
            writes.withValue { $0 += 1 }
            try ApprovalStoreTestPersistence.write(data, url)
        })
        guard case .snapshot(let before) = await tested.configurationSnapshot(configurationKey: key, profileIdentifier: nil) else {
            return XCTFail("Expected valid profile at the authority byte limit")
        }
        guard case .unavailable = await tested.revoke(configurationKey: key, provider: .ethereum,
            attempt: attempt(for: 61_400), expected: before.version, profileIdentifier: nil) else {
            return XCTFail("An oversized authority mutation must not persist")
        }
        XCTAssertEqual(writes.value, 0)
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original)
        guard case .snapshot(let unchanged) = await tested.configurationSnapshot(configurationKey: key, profileIdentifier: nil) else {
            return XCTFail("Rejected revocation must preserve a readable profile")
        }
        XCTAssertEqual(unchanged.version, before.version)
        XCTAssertEqual(unchanged.ethereumChainId, "0xa")

        origins.removeValue(forKey: originKey(399, length: finalLength))
        try seed(origins)
        guard case .revoked(let revoked) = await tested.revoke(configurationKey: key, provider: .ethereum,
            attempt: attempt(for: 61_400), expected: before.version, profileIdentifier: nil),
              case .snapshot(let readable) = await tested.configurationSnapshot(configurationKey: key, profileIdentifier: nil) else {
            return XCTFail("A revocation that fits must persist and remain readable")
        }
        XCTAssertEqual(writes.value, 1)
        XCTAssertEqual(revoked.version.revisions.ethereum, 401)
        XCTAssertEqual(readable.version, revoked.version)
    }

    func testWalletSourceMutationSerializesPreparationAndWritesWithoutRevocation() throws {
        let store = removalStore()
        let competing = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            crossProcessLockTimeoutNanoseconds: 0, crossProcessLockPollNanoseconds: 0
        ))
        let competingLock = CrossProcessFileLock(fileURL: rootURL.appendingPathComponent("bridge-v9.lock"))
        var source = ["original"]
        let competingPreparations = LockedTestValue(0)
        let events = LockedTestValue([String]())
        let result = try store.perform(preparing: {
            events.withValue { $0.append("prepare") }
            XCTAssertFalse(try competingLock.tryAcquire())
            XCTAssertThrowsError(try competing.perform(preparing: {
                competingPreparations.withValue { $0 += 1 }
                return PreparedWalletSourceMutation(payload: source + ["competing"], authorityRemovals: [])
            }, beforeCommit: {}, commit: { source = $0 }))
            XCTAssertEqual(competingPreparations.value, 0)
            return PreparedWalletSourceMutation(payload: source + ["added"], authorityRemovals: [.accounts([])])
        }, beforeCommit: {
            events.withValue { $0.append("invalidate") }
            XCTAssertFalse(try competingLock.tryAcquire())
            XCTAssertEqual(source, ["original"])
        }, commit: { prepared in
            events.withValue { $0.append("commit") }
            XCTAssertFalse(try competingLock.tryAcquire())
            source = prepared
            return source.count
        })
        XCTAssertEqual(result, 2)
        XCTAssertEqual(events.value, ["prepare", "invalidate", "commit"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("profiles-v9").path))
        try competing.perform(preparing: {
            competingPreparations.withValue { $0 += 1 }
            XCTAssertEqual(source, ["original", "added"])
            return PreparedWalletSourceMutation(payload: source + ["competing"], authorityRemovals: [])
        }, beforeCommit: {}, commit: { source = $0 })
        XCTAssertEqual(competingPreparations.value, 1)
        XCTAssertEqual(source, ["original", "added", "competing"])
        XCTAssertTrue(try competingLock.tryAcquire())
        competingLock.release()
    }

    func testWalletSourcePreparationFailureReleasesLockWithoutRevokingAuthority() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 62_980)
        let before = try await removalSnapshot()
        let store = removalStore()
        XCTAssertThrowsError(try store.perform(preparing: { () throws -> PreparedWalletSourceMutation<Void> in
            throw Failure.expectedValue
        }, beforeCommit: {
            XCTFail("Rejected preparation must not invalidate the source")
        }, commit: { _ in
            XCTFail("Rejected preparation must not write the source")
        }))
        let after = try await removalSnapshot()
        XCTAssertEqual(after.ethereumAccount, account)
        XCTAssertEqual(after.version, before.version)
        let result = try store.perform(
            preparing: { PreparedWalletSourceMutation(payload: 42, authorityRemovals: []) },
            beforeCommit: {},
            commit: { $0 }
        )
        XCTAssertEqual(result, 42)
    }

    func testWalletSourceInvalidationFailurePreservesAuthorityAndSource() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 62_979)
        let before = try await removalSnapshot()
        let store = removalStore()
        let competingLock = CrossProcessFileLock(fileURL: rootURL.appendingPathComponent("bridge-v9.lock"))
        let sourceWrites = LockedTestValue(0)
        XCTAssertThrowsError(try store.perform(preparing: {
            PreparedWalletSourceMutation(payload: (), authorityRemovals: [.accounts([account])])
        }, beforeCommit: {
            XCTAssertFalse(try competingLock.tryAcquire())
            throw Failure.injectedWrite
        }, commit: { _ in sourceWrites.withValue { $0 += 1 } }))
        let after = try await removalSnapshot()
        XCTAssertEqual(after.ethereumAccount, account)
        XCTAssertEqual(after.version, before.version)
        XCTAssertEqual(sourceWrites.value, 0)
        XCTAssertTrue(try competingLock.tryAcquire())
        competingLock.release()
    }

    func testWalletSourceTransactionRevokesMultipleScopesBeforeWritingSource() async throws {
        let ethereum = authorityTestAccount()
        let solana = WalletAccountDescriptor(walletID: "another-wallet", coin: .solana,
            normalizedAddress: String(repeating: "1", count: 32), derivationPath: "m/44'/501'/0'/0'")
        _ = try await grantAuthority(ethereum, id: 62_981)
        _ = try await grantAuthority(solana, id: 62_982)
        let store = removalStore()
        let competingLock = CrossProcessFileLock(fileURL: rootURL.appendingPathComponent("bridge-v9.lock"))
        let sourceWrites = LockedTestValue(0)
        try store.perform(preparing: {
            XCTAssertFalse(try competingLock.tryAcquire())
            return PreparedWalletSourceMutation(
                payload: (),
                authorityRemovals: [.accounts([ethereum]), .wallet(id: solana.walletID)]
            )
        }, beforeCommit: {
            XCTAssertFalse(try competingLock.tryAcquire())
        }, commit: { _ in
            XCTAssertFalse(try competingLock.tryAcquire())
            sourceWrites.withValue { $0 += 1 }
        })
        let after = try await removalSnapshot()
        XCTAssertEqual(sourceWrites.value, 1)
        XCTAssertNil(after.ethereumAccount)
        XCTAssertNil(after.solanaAccount)
        XCTAssertTrue(try competingLock.tryAcquire())
        competingLock.release()
    }

    func testScopedRevocationFailurePreventsSourceWriteAndReleasesTransactionLock() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 62_983)
        let store = removalStore(atomicWrite: { _, _ in throw Failure.injectedWrite })
        let preparations = LockedTestValue(0)
        let writes = LockedTestValue(0)
        XCTAssertThrowsError(try store.perform(preparing: {
            preparations.withValue { $0 += 1 }
            return PreparedWalletSourceMutation(payload: (), authorityRemovals: [.accounts([account])])
        }, beforeCommit: {}, commit: { _ in
            writes.withValue { $0 += 1 }
        }))
        XCTAssertEqual(preparations.value, 1)
        XCTAssertEqual(writes.value, 0)
        let after = try await removalSnapshot()
        XCTAssertEqual(after.ethereumAccount, account)
        let result = try removalStore().perform(
            preparing: { PreparedWalletSourceMutation(payload: 42, authorityRemovals: []) },
            beforeCommit: {},
            commit: { $0 }
        )
        XCTAssertEqual(result, 42)
    }

    func testAccountRemovalMatchesExactIdentityAcrossProfilesAndWalletRemovalClearsRemainingGrants() async throws {
        let account = authorityTestAccount()
        let otherWallet = WalletAccountDescriptor(walletID: "other-wallet", coin: account.coin,
            normalizedAddress: account.normalizedAddress, derivationPath: account.derivationPath)
        let otherPath = WalletAccountDescriptor(walletID: account.walletID, coin: account.coin,
            normalizedAddress: account.normalizedAddress, derivationPath: "m/44'/60'/0'/0/1")
        let solana = WalletAccountDescriptor(walletID: account.walletID, coin: .solana,
            normalizedAddress: String(repeating: "1", count: 32), derivationPath: "m/44'/501'/0'/0'")
        let secondProfile = UUID()
        let otherWalletProfile = UUID()
        let otherPathProfile = UUID()
        let original = try await grantAuthority(account, id: 63_000, chainId: "0xa")
        _ = try await grantAuthority(solana, id: 63_001)
        _ = try await grantAuthority(account, id: 63_002, profileIdentifier: secondProfile, host: "second.example")
        _ = try await grantAuthority(otherWallet, id: 63_003, profileIdentifier: otherWalletProfile)
        _ = try await grantAuthority(otherPath, id: 63_004, profileIdentifier: otherPathProfile)
        let before = try await removalSnapshot()
        let store = removalStore()
        let sourceMutations = LockedTestValue(0)
        try store.withRevokedWalletAuthority(matching: .accounts([account])) {
            sourceMutations.withValue { $0 += 1 }
            let competingLock = CrossProcessFileLock(fileURL: rootURL.appendingPathComponent("bridge-v9.lock"))
            XCTAssertFalse(try competingLock.tryAcquire())
            competingLock.release()
        }
        XCTAssertEqual(sourceMutations.value, 1)
        let after = try await removalSnapshot()
        XCTAssertNil(after.ethereumAccount)
        XCTAssertEqual(after.solanaAccount, solana)
        XCTAssertEqual(after.ethereumChainId, "0xa")
        XCTAssertEqual(after.version.context, before.version.context)
        XCTAssertGreaterThan(after.version.revisions.ethereum, before.version.revisions.ethereum)
        XCTAssertEqual(after.version.revisions.solana, before.version.revisions.solana)
        let second = try await removalSnapshot(profileIdentifier: secondProfile, host: "second.example")
        let unrelated = try await removalSnapshot(profileIdentifier: otherWalletProfile)
        let alternate = try await removalSnapshot(profileIdentifier: otherPathProfile)
        XCTAssertNil(second.ethereumAccount)
        XCTAssertEqual(unrelated.ethereumAccount, otherWallet)
        XCTAssertEqual(alternate.ethereumAccount, otherPath)
        let replay = try await deliveredAuthority(original.handle)
        XCTAssertEqual(replay.response["result"] as? [String], [account.normalizedAddress])
        XCTAssertEqual((replay.state["ethereum"] as? [String: String])?["address"], "")

        try store.withRevokedWalletAuthority(matching: .accounts([account])) {}
        let repeated = try await removalSnapshot()
        XCTAssertEqual(repeated.version, after.version)
        try store.withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) {}
        let removedWallet = try await removalSnapshot()
        let removedPath = try await removalSnapshot(profileIdentifier: otherPathProfile)
        let retainedWallet = try await removalSnapshot(profileIdentifier: otherWalletProfile)
        XCTAssertNil(removedWallet.solanaAccount)
        XCTAssertNil(removedPath.ethereumAccount)
        XCTAssertEqual(retainedWallet.version, unrelated.version)
        XCTAssertEqual(retainedWallet.ethereumAccount, otherWallet)
    }

    @MainActor
    func testWalletRemovalFencesSigningAndUncommittedSelectionsButKeepsBroadcastAndCompletedResults() async throws {
        let account = authorityTestAccount()
        let grant = try await grantAuthority(account, id: 63_010)
        let pending = try await admittedSigning(account, id: 63_011)
        let claimed = try await admittedSigning(account, id: 63_012)
        let claim = try approvalClaim(await bridge.claim(handle: claimed.handle))
        let permit = try await reviewedExecution(claim)
        let broadcast = try await admittedBroadcast(account, id: 63_013)
        let broadcastClaim = try approvalClaim(await bridge.claim(handle: broadcast.handle))
        let broadcastPermit = try await reviewedExecution(broadcastClaim)
        let checkpoint = await prepareReviewedBroadcast(broadcastPermit, in: bridge)
        XCTAssertEqual(checkpoint, .persisted)
        let selection = try makeFixture(id: 63_014, name: "requestAccounts", host: "selection.example")
        let selectionHandle = try accepted(await bridge.enqueue(ingress: selection.ingress, profileIdentifier: nil)).handle
        let selectionClaim = try approvalClaim(await bridge.claim(handle: selectionHandle))
        let selectionPermit = try await reviewedExecution(selectionClaim, accounts: [account])
        let native = try makeFixture(id: 63_015, name: "requestAccounts", host: "native.example")
        let nativeHandle = try accepted(await bridge.enqueue(ingress: native.ingress, profileIdentifier: nil)).handle
        _ = try await recordNativeDelivery(handle: nativeHandle)
        guard case .claimed(let nativeClaim) = await claimDeliveredNativeExecution(
            in: bridge, handle: nativeHandle, approvedAt: clock.now
        ) else { return XCTFail("Expected native claim") }
        defer { nativeClaim.releaseUnapproved() }
        let manual = try makeManualFixture(id: 63_016, enqueueAttempt: attempt(for: 63_016), latestConfigurations: [],
            host: "manual.example", configurationKey: "https://manual.example")
        let manualHandle = try accepted(await bridge.enqueue(ingress: manual.ingress, profileIdentifier: nil)).handle
        let solanaTemplate = try makeFixture(id: 63_017, host: "solana.example")
        var solanaRaw = try XCTUnwrap(JSONSerialization.jsonObject(with: solanaTemplate.ingress.canonicalData) as? [String: Any])
        solanaRaw["name"] = "connect"
        solanaRaw["provider"] = "solana"
        solanaRaw["body"] = ["publicKey": "", "object": [:]]
        let solana = try authorityFixture(solanaRaw)
        let solanaHandle = try accepted(await bridge.enqueue(ingress: solana.ingress, profileIdentifier: nil)).handle

        try removalStore().withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) {}
        for handle in [pending.handle, claimed.handle, selectionHandle, nativeHandle, manualHandle, solanaHandle] {
            let delivery = try await deliveredAuthority(handle)
            XCTAssertEqual((delivery.response["error"] as? [String: Any])?["code"] as? Int, 4100)
        }
        _ = await completeReviewedExecution(selectionPermit, in: bridge)
        _ = await completeReviewedExecution(permit, in: bridge)
        let selectionState = try await removalSnapshot(host: "selection.example")
        XCTAssertNil(selectionState.ethereumAccount)
        let broadcastCompletion = await completeReviewedExecution(broadcastPermit, in: bridge)
        XCTAssertEqual(broadcastCompletion, .persisted)
        let broadcastDelivery = try await deliveredAuthority(broadcast.handle)
        XCTAssertEqual(broadcastDelivery.response["approvalCommitted"] as? Bool, true)
        let completedGrant = try await deliveredAuthority(grant.handle)
        XCTAssertEqual(completedGrant.response["kind"] as? String, "result")
    }

    func testWalletRemovalPreservesWarmConnectionsForUnrelatedEthereumAndSolanaGrants() async throws {
        let removedAccount = authorityTestAccount()
        let ethereum = WalletAccountDescriptor(walletID: "retained-ethereum-wallet", coin: .ethereum,
            normalizedAddress: "0x0000000000000000000000000000000000000043", derivationPath: "m/44'/60'/0'/0/0")
        let solana = WalletAccountDescriptor(walletID: "retained-solana-wallet", coin: .solana,
            normalizedAddress: String(repeating: "1", count: 32), derivationPath: "m/44'/501'/0'/0'")
        _ = try await grantAuthority(removedAccount, id: 63_060, host: "removed.example")
        _ = try await grantAuthority(ethereum, id: 63_061)
        _ = try await grantAuthority(solana, id: 63_062)
        let before = try await removalSnapshot()
        let ethereumRequest = try makeFixture(id: 63_063, name: "requestAccounts")
        let ethereumHandle = try accepted(await bridge.enqueue(ingress: ethereumRequest.ingress, profileIdentifier: nil)).handle
        let solanaTemplate = try makeFixture(id: 63_064)
        var solanaRaw = try XCTUnwrap(JSONSerialization.jsonObject(with: solanaTemplate.ingress.canonicalData) as? [String: Any])
        solanaRaw["name"] = "connect"
        solanaRaw["provider"] = "solana"
        solanaRaw["body"] = ["publicKey": solana.normalizedAddress, "object": [:]]
        let solanaRequest = try authorityFixture(solanaRaw)
        let solanaHandle = try accepted(await bridge.enqueue(ingress: solanaRequest.ingress, profileIdentifier: nil)).handle

        try removalStore().withRevokedWalletAuthority(matching: .wallet(id: removedAccount.walletID)) {}
        for (handle, account) in [(ethereumHandle, ethereum), (solanaHandle, solana)] {
            guard case .found(let snapshot) = await bridge.load(handle: handle) else {
                return XCTFail("An unrelated warm connection must remain available")
            }
            XCTAssertEqual(snapshot.phase, .queued)
            XCTAssertEqual(snapshot.request?.authorizedAccount, account)
            let current = await bridge.authorityIsCurrent(handle: handle)
            XCTAssertTrue(current)
        }
        let after = try await removalSnapshot()
        XCTAssertEqual(after.version, before.version)
        XCTAssertEqual(after.ethereumAccount, ethereum)
        XCTAssertEqual(after.solanaAccount, solana)
    }

    func testWalletRemovalRequiresReconnectEvenWhenTheIdenticalDescriptorReturns() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 63_020)
        let before = try Data(contentsOf: defaultProfileURL)
        try removalStore().withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) {}
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), before)
        let removed = try await removalSnapshot()
        let signing = try makeFixture(id: 63_021, name: "signPersonalMessage")
        guard case .unauthorized = await bridge.enqueue(ingress: signing.ingress, profileIdentifier: nil) else {
            return XCTFail("Returning the same wallet must not restore its old grant")
        }
        _ = try await grantAuthority(account, id: 63_022)
        let reconnected = try await removalSnapshot()
        XCTAssertEqual(reconnected.ethereumAccount, account)
        XCTAssertGreaterThan(reconnected.version.revisions.ethereum, removed.version.revisions.ethereum)
    }

    @MainActor
    func testRemovalBeforeBroadcastCheckpointPreventsSubmission() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 63_070)
        let signing = try await admittedBroadcast(account, id: 63_071)
        let claim = try approvalClaim(await bridge.claim(handle: signing.handle))
        let permit = try await reviewedExecution(claim)
        defer { permit.releaseLease() }
        try removalStore().withRevokedWalletAuthority(matching: .accounts([account])) {}
        let checkpoint = await prepareReviewedBroadcast(permit, in: bridge)
        XCTAssertEqual(checkpoint, .ownershipLost)
        let delivered = try await deliveredAuthority(signing.handle)
        XCTAssertEqual((delivered.response["error"] as? [String: Any])?["code"] as? Int, 4100)
    }

    @MainActor
    func testLostRevocationHistoryResetsGrantsLazilyWithoutDiscardingJournal() async throws {
        let account = authorityTestAccount()
        for (index, corrupt) in [false, true].enumerated() {
            let baseID = 63_100 + index * 10
            let dormantID = UUID()
            let connected = try await grantAuthority(account, id: baseID)
            _ = try await grantAuthority(account, id: baseID + 1, profileIdentifier: dormantID)
            let pending = try await admittedSigning(account, id: baseID + 2)
            let broadcast = try await admittedBroadcast(account, id: baseID + 3)
            let claim = try approvalClaim(await bridge.claim(handle: broadcast.handle))
            let permit = try await reviewedExecution(claim)
            defer { permit.releaseLease() }
            let recovery = permit.recoveryResponse
            let checkpoint = await prepareReviewedBroadcast(permit, in: bridge)
            XCTAssertEqual(checkpoint, .persisted)
            let originalReply = try await deliveredAuthority(connected.handle)
            let before = try await removalSnapshot()
            let dormantData = try Data(contentsOf: profileURL(dormantID))
            let oldEpoch = try storedRevocationLedger().cursor.epoch
            if corrupt {
                try Data("damaged ledger".utf8).write(to: revocationLedgerURL)
            } else {
                try FileManager.default.removeItem(at: revocationLedgerURL)
            }

            let reset = try await removalSnapshot()
            XCTAssertNil(reset.ethereumAccount)
            XCTAssertEqual(reset.version.context, before.version.context)
            XCTAssertGreaterThan(reset.version.revisions.ethereum, before.version.revisions.ethereum)
            XCTAssertNotEqual(try storedRevocationLedger().cursor.epoch, oldEpoch)
            XCTAssertEqual(try Data(contentsOf: profileURL(dormantID)), dormantData)
            let pendingReply = try await deliveredAuthority(pending.handle)
            XCTAssertEqual((pendingReply.response["error"] as? [String: Any])?["code"] as? Int, 4100)
            let completedReply = try await deliveredAuthority(connected.handle)
            XCTAssertTrue(NSDictionary(dictionary: originalReply.response).isEqual(to: completedReply.response))
            let completion = await completeReviewedExecution(permit, in: bridge)
            XCTAssertEqual(completion, .persisted)
            let broadcastReply = try await deliveredAuthority(broadcast.handle)
            XCTAssertTrue(NSDictionary(dictionary: recovery.json).isEqual(to: broadcastReply.response))
            let dormant = try await removalSnapshot(profileIdentifier: dormantID)
            XCTAssertNil(dormant.ethereumAccount)
        }
    }

    func testUnreadableOrUnsafeRevocationHistoryBlocksSourceWithoutOverwritingIt() throws {
        try removalStore().withRevokedWalletAuthority(matching: .wallet(id: "old-wallet")) {}
        let original = try Data(contentsOf: revocationLedgerURL)
        let sourceWrites = LockedTestValue(0)
        let unreadable = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            readData: { _ in throw Failure.injectedWrite }
        ))
        XCTAssertThrowsError(try unreadable.withRevokedWalletAuthority(matching: .wallet(id: "new-wallet")) {
            sourceWrites.withValue { $0 += 1 }
        })
        XCTAssertEqual(try Data(contentsOf: revocationLedgerURL), original)

        let target = rootURL.appendingPathComponent("preserved-ledger")
        try FileManager.default.moveItem(at: revocationLedgerURL, to: target)
        try FileManager.default.createSymbolicLink(at: revocationLedgerURL, withDestinationURL: target)
        XCTAssertThrowsError(try removalStore().withRevokedWalletAuthority(matching: .wallet(id: "new-wallet")) {
            sourceWrites.withValue { $0 += 1 }
        })
        XCTAssertEqual(sourceWrites.value, 0)
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: revocationLedgerURL.path), target.path)
    }

    func testFutureRevocationCursorBlocksOnlyItsProfileAndDoesNotPreventRemoval() async throws {
        let account = authorityTestAccount()
        let other = WalletAccountDescriptor(walletID: "retained-wallet", coin: account.coin,
            normalizedAddress: account.normalizedAddress, derivationPath: account.derivationPath)
        let otherProfile = UUID()
        _ = try await grantAuthority(account, id: 63_130)
        _ = try await grantAuthority(other, id: 63_131, profileIdentifier: otherProfile)
        let before = try await removalSnapshot(profileIdentifier: otherProfile)
        let ledger = try storedRevocationLedger()
        var damaged = try storedProfile()
        var cursor = try XCTUnwrap(damaged["revocationCursor"] as? [String: Any])
        cursor["sequence"] = ledger.sequence + 10
        damaged["revocationCursor"] = cursor
        let damagedData = try PropertyListSerialization.data(fromPropertyList: damaged, format: .binary, options: 0)
        try damagedData.write(to: defaultProfileURL)
        let removed = LockedTestValue(false)
        try removalStore().withRevokedWalletAuthority(matching: .accounts([account])) { removed.value = true }
        XCTAssertTrue(removed.value)
        guard case .unavailable = await bridge.configurationSnapshot(
            configurationKey: "https://wallet.example", profileIdentifier: nil
        ) else { return XCTFail("A future cursor must never be rewound") }
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), damagedData)
        XCTAssertEqual(try storedRevocationLedger().cursor.epoch, ledger.cursor.epoch)
        let retained = try await removalSnapshot(profileIdentifier: otherProfile)
        XCTAssertEqual(retained.version, before.version)
        XCTAssertEqual(retained.ethereumAccount, other)
    }

    func testFailedSourceMutationRevokesAgainAfterFreshConsent() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 63_140)
        XCTAssertThrowsError(try removalStore().withRevokedWalletAuthority(matching: .accounts([account])) {
            throw Failure.injectedWrite
        })
        let removed = try await removalSnapshot()
        XCTAssertNil(removed.ethereumAccount)
        _ = try await grantAuthority(account, id: 63_141)
        let reconnected = try await removalSnapshot()
        XCTAssertEqual(reconnected.ethereumAccount, account)
        try removalStore().withRevokedWalletAuthority(matching: .accounts([account])) {}
        let removedAgain = try await removalSnapshot()
        XCTAssertNil(removedAgain.ethereumAccount)
        XCTAssertGreaterThan(removedAgain.version.revisions.ethereum, reconnected.version.revisions.ethereum)
    }

    func testWalletRemovalDoesNotReadOrPrepareProfileDirectories() throws {
        let callbackLedgerURL = revocationLedgerURL
        let sourceMutations = LockedTestValue(0)
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            atomicWrite: { data, url in
                XCTAssertEqual(url, callbackLedgerURL)
                try ApprovalStoreTestPersistence.write(data, url)
            },
            readData: { url in
                XCTAssertEqual(url, callbackLedgerURL)
                return try Data(contentsOf: url)
            },
            readFileSize: { url in
                XCTAssertEqual(url, callbackLedgerURL)
                return try ExtensionRequestFileStore.defaultReadFileSize(url)
            }
        ))
        let result = try store.withRevokedWalletAuthority(matching: .wallet(id: "wallet")) {
            sourceMutations.withValue { $0 += 1 }
            return 42
        }
        XCTAssertEqual(result, 42)
        for name in ["profiles-v9", "operation-locks-v9"] {
            let url = rootURL.appendingPathComponent(name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            try Data([1]).write(to: url)
        }
        try store.withRevokedWalletAuthority(matching: .wallet(id: "wallet")) {
            sourceMutations.withValue { $0 += 1 }
        }
        XCTAssertEqual(sourceMutations.value, 2)
        for name in ["profiles-v9", "operation-locks-v9"] {
            XCTAssertEqual(try Data(contentsOf: rootURL.appendingPathComponent(name)), Data([1]))
        }
    }

    func testWalletRemovalDefersCorruptAndUnsafeProfilesUntilTheyAreAccessed() async throws {
        let callbackLedgerURL = revocationLedgerURL
        let account = authorityTestAccount()
        let dormantID = UUID()
        _ = try await grantAuthority(account, id: 63_030, profileIdentifier: dormantID)
        let dormantURL = profileURL(dormantID)
        let original = try Data(contentsOf: dormantURL)
        let before = try await removalSnapshot(profileIdentifier: dormantID)
        try Data([1]).write(to: dormantURL)
        let unsafeURL = profileURL(UUID())
        try FileManager.default.createSymbolicLink(at: unsafeURL, withDestinationURL: dormantURL)
        let sourceMutations = LockedTestValue(0)
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            atomicWrite: ApprovalStoreTestPersistence.write,
            readData: { url in
                guard url == callbackLedgerURL else { throw Failure.injectedWrite }
                return try Data(contentsOf: url)
            }
        ))
        try store.withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) { sourceMutations.withValue { $0 += 1 } }
        XCTAssertEqual(sourceMutations.value, 1)
        XCTAssertEqual(try Data(contentsOf: dormantURL), Data([1]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: unsafeURL.path), dormantURL.path)
        try original.write(to: dormantURL, options: .atomic)
        let after = try await removalSnapshot(profileIdentifier: dormantID)
        XCTAssertNil(after.ethereumAccount)
        XCTAssertEqual(after.version.context, before.version.context)
        XCTAssertGreaterThan(after.version.revisions.ethereum, before.version.revisions.ethereum)
    }

    func testLedgerFailureBlocksSourceAndProfileCatchUpFailureCannotSkipRevocation() async throws {
        let callbackLedgerURL = revocationLedgerURL
        let callbackProfileURL = defaultProfileURL
        let account = authorityTestAccount()
        let secondProfile = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        _ = try await grantAuthority(account, id: 63_040)
        _ = try await grantAuthority(account, id: 63_041, profileIdentifier: secondProfile)
        let originalDefault = try Data(contentsOf: defaultProfileURL)
        let originalSecond = try Data(contentsOf: profileURL(secondProfile))
        let sourceMutations = LockedTestValue(0)
        let failingStore = removalStore(atomicWrite: { _, url in
            XCTAssertEqual(url, callbackLedgerURL)
            throw Failure.injectedWrite
        })
        XCTAssertThrowsError(try failingStore.withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) {
            sourceMutations.withValue { $0 += 1 }
        })
        XCTAssertEqual(sourceMutations.value, 0)
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), originalDefault)
        XCTAssertEqual(try Data(contentsOf: profileURL(secondProfile)), originalSecond)
        try removalStore().withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) { sourceMutations.withValue { $0 += 1 } }
        XCTAssertEqual(sourceMutations.value, 1)
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), originalDefault)
        XCTAssertEqual(try Data(contentsOf: profileURL(secondProfile)), originalSecond)

        let unavailable = removalStore(atomicWrite: { _, url in
            XCTAssertEqual(url, callbackProfileURL)
            throw Failure.injectedWrite
        })
        guard case .unavailable = unavailable.configurationSnapshot(configurationKey: "https://wallet.example", profileIdentifier: nil) else {
            return XCTFail("Failed catch-up must not expose authority")
        }
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), originalDefault)
        let retried = try await removalSnapshot(profileIdentifier: secondProfile)
        let fullyRemoved = try await removalSnapshot()
        let repeated = try await removalSnapshot()
        XCTAssertNil(retried.ethereumAccount)
        XCTAssertNil(fullyRemoved.ethereumAccount)
        XCTAssertEqual(repeated.version, fullyRemoved.version)
    }

    func testWalletRemovalConfirmsLedgerDurabilityAndKeepsRevocationWhenSourceFails() async throws {
        _ = try authorityVersion("https://empty.example")
        let sourceMutations = LockedTestValue(0)
        let failingStore = removalStore(atomicWrite: { data, url in
            try ApprovalStoreTestPersistence.write(data, url)
            throw Failure.injectedWrite
        }, synchronizePublishedFile: { _ in throw Failure.injectedWrite })
        XCTAssertThrowsError(try failingStore.withRevokedWalletAuthority(matching: .wallet(id: "absent-wallet")) {
            sourceMutations.withValue { $0 += 1 }
        })
        XCTAssertEqual(sourceMutations.value, 0)
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 63_050)
        XCTAssertThrowsError(try removalStore().withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) {
            sourceMutations.withValue { $0 += 1 }
            throw Failure.injectedWrite
        })
        let removed = try await removalSnapshot()
        XCTAssertNil(removed.ethereumAccount)
        try removalStore().withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) { sourceMutations.withValue { $0 += 1 } }
        let retried = try await removalSnapshot()
        XCTAssertEqual(sourceMutations.value, 2)
        XCTAssertEqual(retried.version, removed.version)
    }

    private func removalStore(
        atomicWrite: ExtensionRequestFileStore.AtomicWrite? = ApprovalStoreTestPersistence.write,
        synchronizePublishedFile: ExtensionRequestFileStore.SynchronizePublishedFile? = nil
    ) -> ExtensionRequestFileStore {
        ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { [clock = clock!] in clock.now }, atomicWrite: atomicWrite, synchronizePublishedFile: synchronizePublishedFile
        ))
    }

    private func removalSnapshot(profileIdentifier: UUID? = nil, host: String = "wallet.example") async throws -> ExtensionBridge.AuthoritySnapshot {
        guard case .snapshot(let snapshot) = await bridge.configurationSnapshot(
            configurationKey: "https://\(host)", profileIdentifier: profileIdentifier
        ) else { throw Failure.expectedValue }
        return snapshot
    }

    private func authorityTestAccount() -> WalletAccountDescriptor {
        .init(walletID: "native-store-wallet", coin: .ethereum,
              normalizedAddress: "0x0000000000000000000000000000000000000042", derivationPath: "m/44'/60'/0'/0/0")
    }

    private func authorityFixture(_ object: [String: Any]) throws -> Fixture {
        let request = try XCTUnwrap(SafariRequest(json: object))
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(request: request, rawObject: object) else { throw Failure.expectedValue }
        return Fixture(request: request, ingress: ingress)
    }

    private func grantAuthority(
        _ account: WalletAccountDescriptor, id: Int, profileIdentifier: UUID? = nil,
        host: String = "wallet.example", chainId: String = "0x1"
    ) async throws -> (request: SafariRequest, handle: ExtensionBridge.Handle) {
        let fixture = try makeFixture(id: id, host: host)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.ingress.canonicalData) as? [String: Any])
        raw["authority"] = try authorityVersion(fixture.request.configurationKey, profileIdentifier: profileIdentifier).json
        raw["name"] = account.coin == .ethereum ? "requestAccounts" : "connect"
        raw["provider"] = account.coin == .ethereum ? "ethereum" : "solana"
        raw["body"] = account.coin == .ethereum ? ["address": "", "chainId": chainId] : ["publicKey": "", "object": [:]]
        let connection = try authorityFixture(raw)
        let handle = try accepted(await bridge.enqueue(ingress: connection.ingress, profileIdentifier: profileIdentifier)).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        XCTAssertTrue(claim.adoptForExecution())
        guard case .found(let snapshot) = await bridge.load(handle: handle) else { throw Failure.expectedValue }
        let resolved = try await resolvedApprovalForTesting(
            snapshot: snapshot,
            action: .selectAccount(.init(coinType: account.coin, selectedAccounts: [], initiallyConnectedProviders: [], network: Networks.withChainIdHex(chainId))),
            decision: .accountSelection(.init(accounts: [account], ethereumChainID: chainId)),
            accounts: [account.specificAccount], approvedAt: clock.now
        )
        guard case .authorized(let authorized) = await bridge.authorize(claim: claim, approval: resolved),
              authorized.consumeExecution(),
              let result = ApprovedCompletion.accountSelection(permit: authorized) else { throw Failure.expectedValue }
        let completion = await bridge.complete(permit: authorized, result: result)
        XCTAssertEqual(completion, .persisted)
        return (connection.request, handle)
    }

    private func admittedBroadcast(_ account: WalletAccountDescriptor, id: Int) async throws -> (request: SafariRequest, handle: ExtensionBridge.Handle) {
        let fixture: Fixture
        if account.coin == .ethereum {
            fixture = try makeTransactionFixture(id: id)
        } else {
            let template = try makeFixture(id: id)
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: template.ingress.canonicalData) as? [String: Any])
            let publicKey = try XCTUnwrap(WalletCrypto.base58Decode(string: account.normalizedAddress))
            let message = Data([1, 0, 0, 1]) + publicKey + Data(repeating: 0, count: 32) + Data([0])
            raw["provider"] = "solana"
            raw["name"] = "signAndSendTransaction"
            raw["body"] = ["publicKey": account.normalizedAddress, "object": ["params": ["message": WalletCrypto.base58Encode(data: message)]]]
            fixture = try authorityFixture(raw)
        }
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        return (fixture.request, handle)
    }

    private func admittedSigning(_ account: WalletAccountDescriptor, id: Int) async throws -> (request: SafariRequest, handle: ExtensionBridge.Handle) {
        let fixture = try makeFixture(id: id)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.ingress.canonicalData) as? [String: Any])
        raw["name"] = "signPersonalMessage"
        let signing = try authorityFixture(raw)
        let handle = try accepted(await bridge.enqueue(ingress: signing.ingress, profileIdentifier: nil)).handle
        guard case .found(let stored) = await bridge.load(handle: handle) else { throw Failure.expectedValue }
        XCTAssertEqual(stored.request?.authorizedAccount, account)
        return (signing.request, handle)
    }

    private func deliveredAuthority(_ handle: ExtensionBridge.Handle) async throws -> (response: [String: Any], state: [String: Any]) {
        guard case .found(let snapshot) = await bridge.load(handle: handle),
              case .response(let envelope) = await bridge.prepareResponseDelivery(id: handle.id,
                configurationKey: snapshot.configurationKey, requestToken: handle.requestToken, profileIdentifier: handle.profileIdentifier) else {
            throw Failure.expectedValue
        }
        return (try XCTUnwrap(envelope["response"] as? [String: Any]), try XCTUnwrap(envelope["state"] as? [String: Any]))
    }

    func testObservationalReadsDoNotCreateFreshStorage() async throws {
        try FileManager.default.removeItem(at: rootURL)
        let handle = ExtensionBridge.Handle(id: 1, token: .init(value: UUID()), profileIdentifier: nil)
        let response = await bridge.responseStatus(handle: handle, configurationKey: "https://wallet.example")

        XCTAssertEqual(response, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testObservationalReadsDoNotRecoverExpiredOrAbandonedRequests() async throws {
        let manual = try makeManualFixture(
            id: 950, enqueueAttempt: attempt(for: 950), latestConfigurations: []
        )
        let manualHandle = try accepted(await bridge.enqueue(ingress: manual.ingress, profileIdentifier: nil)).handle
        let ordinary = try makeFixture(id: 951)
        let ordinaryHandle = try accepted(await bridge.enqueue(ingress: ordinary.ingress, profileIdentifier: nil)).handle
        guard case .claimed(let claim) = await bridge.claim(handle: ordinaryHandle) else {
            return XCTFail("Expected ordinary claim")
        }
        claim.releaseUnapproved()
        clock.now = manual.request.admissionDeadline.addingTimeInterval(1)
        let original = try Data(contentsOf: defaultProfileURL)
        let originalPaths = try FileManager.default.subpathsOfDirectory(atPath: rootURL.path).sorted()
        let observer = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { _, _ in XCTFail("Observation wrote storage"); throw Failure.injectedWrite },
            synchronizePublishedFile: { _ in XCTFail("Observation synchronized storage"); throw Failure.injectedWrite }
        )
        let manualStatus = await observer.responseStatus(
            handle: manualHandle, configurationKey: manual.request.configurationKey
        )

        let ordinaryStatus = await observer.responseStatus(
            handle: ordinaryHandle, configurationKey: ordinary.request.configurationKey
        )
        XCTAssertEqual(manualStatus, .pending)
        XCTAssertEqual(ordinaryStatus, .pending)
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: rootURL.path).sorted(), originalPaths)
    }

    func testAuthorityReconciliationDoesNotRecoverUnrelatedRequests() async throws {
        for interrupt in [false, true] {
            let id = interrupt ? 986 : 983
            let target = try makeFixture(id: id)
            let admission = try accepted(await bridge.enqueue(ingress: target.ingress, profileIdentifier: nil))
            let owner = storedRequestNativeOwner()
            if interrupt {
                let result = await bridge.recordNativeDeliveryReceipt(
                    handle: admission.handle, nativeDeliveryNonce: admission.nativeDeliveryNonce, owner: owner
                )
                XCTAssertEqual(result, .persisted)
            }
            let expired = try makeFixture(id: id + 1, admissionDeadline: clock.now.addingTimeInterval(1))
            _ = try accepted(await bridge.enqueue(ingress: expired.ingress, profileIdentifier: nil))
            let abandoned = try makeFixture(id: id + 2)
            let abandonedHandle = try accepted(await bridge.enqueue(ingress: abandoned.ingress, profileIdentifier: nil)).handle
            let claim = try approvalClaim(await bridge.claim(handle: abandonedHandle))
            claim.releaseUnapproved()
            clock.now = clock.now.addingTimeInterval(2)
            let recordsBefore = try XCTUnwrap(storedProfile()["records"] as? [[String: Any]])
                .filter { ($0["id"] as? Int) == id + 1 || ($0["id"] as? Int) == id + 2 }
            XCTAssertEqual(recordsBefore.count, 2)

            if interrupt {
                let result = await bridge.interruptNativeApproval(
                    handle: admission.handle, nativeDeliveryNonce: admission.nativeDeliveryNonce,
                    runtimeInstanceIdentifier: owner.runtimeInstanceIdentifier
                )
                XCTAssertEqual(result, .interrupted)
            } else {
                let result = await bridge.completeImmediate(
                    handle: admission.handle, resolution: immediateResolution(for: target.request)
                )
                XCTAssertEqual(result, .persisted)
            }

            let recordsAfter = try XCTUnwrap(storedProfile()["records"] as? [[String: Any]])
                .filter { ($0["id"] as? Int) == id + 1 || ($0["id"] as? Int) == id + 2 }
            XCTAssertEqual(recordsAfter as NSArray, recordsBefore as NSArray)
            XCTAssertTrue(FileManager.default.fileExists(atPath: operationLockURL(abandonedHandle).path))
        }
    }

    func testAuthorityReconciliationDoesNotRepairPermissionCorruption() async throws {
        for interrupt in [false, true] {
            let target = try makeFixture(id: interrupt ? 989 : 988)
            let admission = try accepted(await bridge.enqueue(ingress: target.ingress, profileIdentifier: nil))
            let owner = storedRequestNativeOwner()
            if interrupt {
                let result = await bridge.recordNativeDeliveryReceipt(
                    handle: admission.handle, nativeDeliveryNonce: admission.nativeDeliveryNonce, owner: owner
                )
                XCTAssertEqual(result, .persisted)
            }
            try mutateStoredPermissions { $0[target.request.configurationKey] = "incompatible permissions" }
            let original = try Data(contentsOf: defaultProfileURL)
            let strict = makeBridge(
                clock: { [clock = clock!] in clock.now },
                atomicWrite: { _, _ in XCTFail("Authority reconciliation repaired storage"); throw Failure.injectedWrite },
                synchronizePublishedFile: { _ in XCTFail("Authority reconciliation synchronized storage"); throw Failure.injectedWrite }
            )

            if interrupt {
                let result = await strict.interruptNativeApproval(
                    handle: admission.handle, nativeDeliveryNonce: admission.nativeDeliveryNonce,
                    runtimeInstanceIdentifier: owner.runtimeInstanceIdentifier
                )
                XCTAssertEqual(result, .retryablePersistenceFailure)
            } else {
                let result = await strict.completeImmediate(
                    handle: admission.handle, resolution: immediateResolution(for: target.request)
                )
                XCTAssertEqual(result, .retryablePersistenceFailure)
            }
            XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original)
        }
    }

    func testReadyStatusDoesNotSynchronizeOrAcknowledgeResponse() async throws {
        let fixture = try makeFixture(id: 952)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let completed = await bridge.completeImmediate(handle: handle, resolution: immediateResolution(for: fixture.request))
        XCTAssertEqual(completed, .persisted)
        let original = try Data(contentsOf: defaultProfileURL)
        let synchronizations = LockedTestValue(0)
        let observer = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { _, _ in XCTFail("Observation wrote storage"); throw Failure.injectedWrite },
            synchronizePublishedFile: { _ in synchronizations.withValue { $0 += 1 }; throw Failure.injectedWrite }
        )
        let status = await observer.responseStatus(handle: handle, configurationKey: fixture.request.configurationKey)

        let wrongIdentity = await observer.responseStatus(handle: handle, configurationKey: "https://other.example")
        XCTAssertEqual(status, .ready)

        XCTAssertEqual(wrongIdentity, .missing)
        XCTAssertEqual(synchronizations.value, 0)
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original)
        guard case .unavailable = await observer.prepareResponseDelivery(
            id: handle.id, configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken, profileIdentifier: nil
        ) else { return XCTFail("Delivery must still require its durability barrier") }
        XCTAssertEqual(synchronizations.value, 1)
    }

    func testObservationalReadsRejectMissingAndUnsafeExistingStoreLocks() async throws {
        let fixture = try makeFixture(id: 953)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let lockURL = rootURL.appendingPathComponent("bridge-v9.lock")
        try FileManager.default.removeItem(at: lockURL)
        let missingLock = await bridge.responseStatus(handle: handle, configurationKey: fixture.request.configurationKey)
        XCTAssertEqual(missingLock, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: defaultProfileURL)
        let original = try Data(contentsOf: defaultProfileURL)

        let unsafeStatus = await bridge.responseStatus(handle: handle, configurationKey: fixture.request.configurationKey)
        XCTAssertEqual(unsafeStatus, .unavailable)
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original)
    }

    func testObservationalReadsPreserveFutureDatesAndExpiredCompletedResponses() async throws {
        let fixture = try makeManualFixture(
            id: 958, enqueueAttempt: attempt(for: 958), latestConfigurations: []
        )
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let completed = await bridge.completeImmediate(handle: handle, resolution: immediateResolution(for: fixture.request))
        XCTAssertEqual(completed, .persisted)
        let future = clock.now.addingTimeInterval(ExtensionBridge.responseExpiry)
        try mutateFirstStoredRecord { record in
            record["createdAt"] = future
            record["admissionCreatedAt"] = future
            var state = try XCTUnwrap(record["state"] as? [String: Any])
            var completed = try XCTUnwrap(state["completed"] as? [String: Any])
            completed["since"] = future
            state["completed"] = completed
            record["state"] = state
        }
        let original = try Data(contentsOf: defaultProfileURL)
        let observer = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { _, _ in XCTFail("Observation wrote storage"); throw Failure.injectedWrite },
            synchronizePublishedFile: { _ in XCTFail("Observation synchronized storage"); throw Failure.injectedWrite }
        )
        for observedAt in [clock.now, future.addingTimeInterval(ExtensionBridge.responseExpiry + 1)] {
            clock.now = observedAt
            let status = await observer.responseStatus(
                handle: handle, configurationKey: fixture.request.configurationKey
            )
            XCTAssertEqual(status, .ready)
            XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original)
        }
        await bridge.performMaintenance(profileIdentifier: nil)
        let retired = await observer.responseStatus(handle: handle, configurationKey: fixture.request.configurationKey)
        XCTAssertEqual(retired, .missing)
    }

    @MainActor
    func testObservationalReadsDoNotRecoverOrSynchronizeBroadcastCheckpoint() async throws {
        let execution = try await makeExecutableNativePermit(id: 959)
        let checkpoint = await prepareReviewedBroadcast(execution.permit)
        XCTAssertEqual(checkpoint, .persisted)
        execution.permit.releaseLease()

        let original = try Data(contentsOf: defaultProfileURL)
        let originalPaths = try FileManager.default.subpathsOfDirectory(atPath: rootURL.path).sorted()
        let observer = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { _, _ in XCTFail("Observation recovered checkpoint"); throw Failure.injectedWrite },
            synchronizePublishedFile: { _ in XCTFail("Observation synchronized checkpoint"); throw Failure.injectedWrite }
        )
        let response = await observer.responseStatus(
            handle: execution.handle, configurationKey: execution.request.configurationKey
        )

        XCTAssertEqual(response, .pending)

        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: rootURL.path).sorted(), originalPaths)
        await bridge.performMaintenance(profileIdentifier: nil)
        let recovered = await observer.responseStatus(
            handle: execution.handle, configurationKey: execution.request.configurationKey
        )
        XCTAssertEqual(recovered, .ready)
    }

    func testScopedMaintenanceRecoversOnlyItsProfile() async throws {
        let fixture = try makeFixture(id: 954)
        let profile = UUID()
        let first = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let second = try accepted(await bridge.enqueue(ingress: try profileFixture(fixture, profileIdentifier: profile).ingress, profileIdentifier: profile)).handle
        clock.now = fixture.request.admissionDeadline
        let otherData = try Data(contentsOf: profileURL(profile))
        await bridge.performMaintenance(profileIdentifier: nil)
        let firstStatus = await bridge.responseStatus(handle: first, configurationKey: fixture.request.configurationKey)
        let secondStatus = await bridge.responseStatus(handle: second, configurationKey: fixture.request.configurationKey)
        XCTAssertEqual(firstStatus, .ready)
        XCTAssertEqual(secondStatus, .pending)
        XCTAssertEqual(try Data(contentsOf: profileURL(profile)), otherData)
    }

#if os(macOS)
    func testObservationalReadsFailPromptlyUnderStoreLockContention() async throws {
        let fixture = try makeFixture(id: 955)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let original = try Data(contentsOf: defaultProfileURL)
        try await CrossProcessLockTestFixture.withHeldLock(
            at: rootURL.appendingPathComponent("bridge-v9.lock"),
            readyURL: rootURL.appendingPathComponent("observation-holder-ready")
        ) {
            let started = ContinuousClock.now
            let response = await self.bridge.responseStatus(handle: handle, configurationKey: fixture.request.configurationKey)

            XCTAssertEqual(response, .unavailable)
            XCTAssertLessThan(started.duration(to: .now), .milliseconds(500))
        }
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original)
    }
#endif

    func testWorkflowPolicyIsV4AndPrivateBrowsingRemainsUnsupported() async throws {
        XCTAssertEqual(ExtensionBridge.workflowVersion, 4)
        XCTAssertEqual(ExtensionBridge.maximumRequests, 8)
        XCTAssertEqual(ExtensionBridge.maximumRequestsPerHost, 4)
        XCTAssertEqual(ExtensionBridge.maximumRetainedRequests, 16)
        XCTAssertEqual(ExtensionBridge.maximumRetainedRequestsPerOrigin, 12)
        XCTAssertEqual(ExtensionBridge.requestTTL, 15 * 60)
        XCTAssertEqual(ExtensionBridge.responseExpiry, 60 * 60)

        let fixture = try makeFixture(id: 1)
        guard case .rejected = await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil,
            privateBrowsing: true
        ) else { return XCTFail("Expected private browsing rejection") }
    }

    func testProviderRevisionsDecodingAndEncodingPreserveWireShape() throws {
        let validValues: [[String: Any]] = [
            ["ethereum": 0, "solana": 9_007_199_254_740_991],
            ["ethereum": 9_007_199_254_740_991, "solana": 0],
            ["ethereum": NSNumber(value: 1.0), "solana": NSNumber(value: 2.0)],
        ]
        for rawValue in validValues {
            let expected = try XCTUnwrap(ExtensionBridge.ProviderRevisions(rawValue: rawValue))
            let jsonData = try JSONSerialization.data(withJSONObject: rawValue)
            let decodedJSON = try JSONDecoder().decode(
                ExtensionBridge.ProviderRevisions.self,
                from: jsonData
            )
            XCTAssertEqual(decodedJSON, expected)
            let encodedJSON = try JSONEncoder().encode(decodedJSON)
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: encodedJSON) as? NSDictionary,
                expected.json as NSDictionary
            )

            let plistData = try PropertyListSerialization.data(
                fromPropertyList: rawValue,
                format: .binary,
                options: 0
            )
            let decodedPlist = try PropertyListDecoder().decode(
                ExtensionBridge.ProviderRevisions.self,
                from: plistData
            )
            XCTAssertEqual(decodedPlist, expected)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            XCTAssertEqual(
                try PropertyListSerialization.propertyList(
                    from: encoder.encode(decodedPlist), options: [], format: nil
                ) as? NSDictionary,
                expected.json as NSDictionary
            )
        }
    }

    func testProviderRevisionsDecodingRejectsInvalidWireValues() throws {
        for rawValue in invalidProviderRevisionValues {
            let message = String(describing: rawValue)
            XCTAssertNil(ExtensionBridge.ProviderRevisions(rawValue: rawValue), message)
            let jsonData = try JSONSerialization.data(
                withJSONObject: rawValue,
                options: [.fragmentsAllowed]
            )
            XCTAssertThrowsError(try JSONDecoder().decode(
                ExtensionBridge.ProviderRevisions.self,
                from: jsonData
            ), message)
            if PropertyListSerialization.propertyList(rawValue, isValidFor: .binary) {
                let plistData = try PropertyListSerialization.data(
                    fromPropertyList: rawValue, format: .binary, options: 0
                )
                XCTAssertThrowsError(try PropertyListDecoder().decode(
                    ExtensionBridge.ProviderRevisions.self,
                    from: plistData
                ), message)
            }
        }
    }

    func testInternalRequestsRejectWorkerExecutionAuthority() throws {
        let execution: [String: Any] = [
            "id": 1, "workflowVersion": ExtensionBridge.workflowVersion,
            "subject": "executeNativeApproval", "requestToken": UUID().uuidString.lowercased(),
            "configurationKey": "https://wallet.example",
            "executionDeadline": 1_700_000_160_000,
            "claimID": UUID().uuidString.lowercased(), "revisions": ["ethereum": 0, "solana": 0],
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(InternalSafariRequest.self,
            from: JSONSerialization.data(withJSONObject: execution)))
    }

    private var invalidProviderRevisionValues: [Any] {
        var values: [Any] = [
            [:] as [String: Any],
            ["ethereum": 0],
            ["solana": 0],
            ["ethereum": 0, "solana": 0, "extra": 0],
            "invalid",
            [0, 0],
            NSNull(),
        ]
        for key in ["ethereum", "solana"] {
            for invalid: Any in [-1, 9_007_199_254_740_992, true, false, 1.5, "1", NSNull()] {
                var value: [String: Any] = ["ethereum": 0, "solana": 0]
                value[key] = invalid
                values.append(value)
            }
        }
        return values
    }

    func testCompletionReadFailureIsRetryableWithoutLosingOwnership() async throws {
        let fixture = try makeFixture(id: 742)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress, profileIdentifier: nil
        )).handle
        let unavailable = LockedTestValue(true)
        let writer = makeBridge(clock: { [clock = clock!] in clock.now }, readData: { url in
            if unavailable.value { throw CocoaError(.fileReadUnknown) }
            return try ExtensionRequestFileStore.defaultReadData(url)
        })

        let failed = await writer.completeImmediate(handle: handle, resolution: immediateResolution(for: fixture.request))
        XCTAssertEqual(failed, .retryablePersistenceFailure)
        unavailable.value = false
        let retried = await writer.completeImmediate(handle: handle, resolution: immediateResolution(for: fixture.request))
        XCTAssertEqual(retried, .persisted)
    }

    #if os(macOS)
    func testEmbeddedHelperStaysInsideTheSafariExtensionBundle() throws {
        let extensionURL = URL(fileURLWithPath:
            "/Users/developer/Build/Wallet.app/Contents/PlugIns/Safari macOS.appex",
            isDirectory: true
        )
        let helperURL = try XCTUnwrap(
            NativeAgentRuntime.embeddedHelperURL(in: extensionURL)
        )
        XCTAssertEqual(
            helperURL.path,
            extensionURL.path + "/Contents/Helpers/Big Wallet.app"
        )
        XCTAssertNil(NativeAgentRuntime.embeddedHelperURL(
            in: extensionURL.deletingLastPathComponent()
        ))
        XCTAssertNil(NativeAgentRuntime.embeddedHelperURL(
            in: URL(string: "https://example.com/Safari.appex")!
        ))
    }

    @MainActor
    func testNativeCodeValidationRechecksMappedResourcesOffMainActor() async throws {
        let helperURL = try makeAmbientBundle(name: "Mapped Helper", build: "149")
        let resourceURL = helperURL.appendingPathComponent("Contents/resource")
        try Data([1]).write(to: resourceURL)
        let descriptor = open(resourceURL.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let mapping = try XCTUnwrap(mmap(nil, 1, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0))
        guard mapping != MAP_FAILED else { return XCTFail("Failed to map resource") }
        defer { munmap(mapping, 1) }
        mapping.storeBytes(of: UInt8(1), as: UInt8.self)

        let checks = expectation(description: "Validate every request")
        checks.expectedFulfillmentCount = 4
        checks.assertForOverFulfill = true
        let validator = NativeAgentRuntime.CodeValidator(validate: { _, _ in
            XCTAssertFalse(Thread.isMainThread)
            checks.fulfill()
            return (try? Data(contentsOf: resourceURL)) == Data([1])
        })
        let original = await validator.validate(helperURL: helperURL, extensionURL: helperURL)
        let repeated = await validator.validate(helperURL: helperURL, extensionURL: helperURL)
        XCTAssertTrue(original)
        XCTAssertTrue(repeated)
        mapping.storeBytes(of: UInt8(2), as: UInt8.self)
        let changed = await validator.validate(helperURL: helperURL, extensionURL: helperURL)
        XCTAssertFalse(changed)
        mapping.storeBytes(of: UInt8(1), as: UInt8.self)
        let restored = await validator.validate(helperURL: helperURL, extensionURL: helperURL)
        XCTAssertTrue(restored)
        await fulfillment(of: [checks], timeout: 1)
    }
    #endif

    func testStoreLeavesUnrelatedFilesAndDirectoriesUntouched() async throws {
        var preservedFiles = [URL: Data]()
        for name in ["other-profiles", "other-locks"] {
            let directory = rootURL.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent("unrelated.state")
            let data = Data("preserve unrelated state".utf8)
            try data.write(to: url)
            preservedFiles[url] = data
        }
        let unrelatedURL = rootURL.appendingPathComponent("unrelated.data")
        let unrelated = Data("preserve unrelated data".utf8)
        try unrelated.write(to: unrelatedURL)
        preservedFiles[unrelatedURL] = unrelated

        guard case .available(let initial) = await bridge.list(
            profileIdentifier: nil
        ) else { return XCTFail("Expected empty store") }
        XCTAssertTrue(initial.isEmpty)

        _ = try accepted(await bridge.enqueue(
            ingress: try makeFixture(id: 81).ingress,
            profileIdentifier: nil
        ))
        let profile = try storedProfile()
        XCTAssertEqual(profile["schemaVersion"] as? Int, 9)
        _ = await bridge.list(profileIdentifier: nil)
        for (url, data) in preservedFiles {
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultProfileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL
            .appendingPathComponent("operation-locks-v9", isDirectory: true)
            .path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL
            .appendingPathComponent("bridge-v9.lock").path))
    }

    func testStoreRemovesOrphanedWritesAndPreservesUnrelatedEntries() async throws {
        let profileDirectory = defaultProfileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        let temporaryName = ".profile-write-\(UUID().uuidString.lowercased()).tmp"
        var preservedFiles = [URL: Data]()
        var preservedLinks = [URL]()
        for directory in [rootURL!, profileDirectory] {
            for name in ["unrelated.state", ".profile-write-invalid.tmp", temporaryName + ".extra"] {
                let url = directory.appendingPathComponent(name)
                let data = Data("preserve".utf8)
                try data.write(to: url)
                preservedFiles[url] = data
            }
            let link = directory.appendingPathComponent(temporaryName)
            let target = directory.appendingPathComponent("unrelated.state")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            preservedLinks.append(link)
            let nested = directory.appendingPathComponent(".profile-write-\(UUID().uuidString.lowercased()).tmp")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            let child = nested.appendingPathComponent(temporaryName)
            let data = Data("preserve nested file".utf8)
            try data.write(to: child)
            preservedFiles[child] = data
        }

        for maintenance in [true, false] {
            let orphans = [rootURL!, profileDirectory].map {
                $0.appendingPathComponent(".profile-write-\(UUID().uuidString.lowercased()).tmp")
            }
            for url in orphans { try Data("interrupted snapshot".utf8).write(to: url) }
            if maintenance {
                await bridge.performMaintenance()
            } else {
                guard case .available = await bridge.list(profileIdentifier: nil) else {
                    return XCTFail("Expected available store")
                }
            }
            for url in orphans { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
            for (url, data) in preservedFiles { XCTAssertEqual(try Data(contentsOf: url), data) }
            for url in preservedLinks {
                XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            }
        }
    }

    func testOrphanedWriteCleanupFailureDoesNotBlockRecoveryAndIsRetried() throws {
        let orphan = rootURL.appendingPathComponent(".profile-write-\(UUID().uuidString.lowercased()).tmp")
        try Data("interrupted snapshot".utf8).write(to: orphan)
        let failRemoval = LockedTestValue(true)
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            removeItem: { url in
                if url == orphan, failRemoval.value { throw Failure.injectedWrite }
                try FileManager.default.removeItem(at: url)
            }
        ))
        guard case .available = store.list(profileIdentifier: nil) else {
            return XCTFail("Cleanup failure must not block recovery")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        failRemoval.value = false
        guard case .available = store.list(profileIdentifier: nil) else {
            return XCTFail("Expected available store")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testStoreExcludesBridgeRootFromBackup() async throws {
        var mutableRootURL = try XCTUnwrap(rootURL)
        var includedValues = URLResourceValues()
        includedValues.isExcludedFromBackup = false
        try mutableRootURL.setResourceValues(includedValues)
        XCTAssertEqual(
            try rootURL.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup,
            false
        )

        _ = await bridge.list(profileIdentifier: nil)

        let values = try rootURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    @MainActor
    func testActivePayloadAndResponsesSurviveEveryPersistedState()
        async throws {
        let fixture = try makeTransactionFixture(id: 85)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        XCTAssertEqual(
            try Data(contentsOf: defaultProfileURL).prefix(8),
            Data("bplist00".utf8)
        )
        XCTAssertEqual(
            try firstStoredBody("pending"),
            try bodyData(for: fixture.ingress)
        )
        let payload = try XCTUnwrap(firstStoredState("pending")["request"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["name", "provider", "admissionDeadlineMilliseconds", "bodyData"])
        XCTAssertEqual(payload["admissionDeadlineMilliseconds"] as? Int, fixture.request.admissionDeadlineMilliseconds)
        bridge = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .found(let pending) = await bridge.load(handle: handle) else {
            return XCTFail("Expected pending request after restart")
        }
        XCTAssertEqual(pending.phase, .queued)

        let claim = try approvalClaim(await bridge.claim(handle: handle))
        XCTAssertEqual(
            try firstStoredBody("claimed"),
            try bodyData(for: fixture.ingress)
        )
        bridge = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .found(let claimed) = await bridge.load(handle: handle) else {
            return XCTFail("Expected held claim after restart")
        }
        XCTAssertEqual(claimed.phase, .approving)
        XCTAssertNil(claimed.nativeApproval)
        XCTAssertNil(claimed.nativeExecutionContext)

        let permit = try await reviewedExecution(claim)
        let recovery = permit.recoveryResponse
        let checkpoint = await prepareReviewedBroadcast(permit, in: bridge)
        XCTAssertEqual(checkpoint, .persisted)
        let broadcast = try firstStoredState("broadcastPrepared")
        XCTAssertEqual(try firstStoredBody("broadcastPrepared"), try bodyData(for: fixture.ingress))
        XCTAssertEqual(
            broadcast["recoveryResponse"] as? Data,
            ExtensionBridge.payloadData(recovery.json, options: [.sortedKeys])
        )
        bridge = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .found(let prepared) = await bridge.load(handle: handle) else {
            return XCTFail("Expected held broadcast after restart")
        }
        XCTAssertEqual(prepared.phase, .approving)

        let response = permit.response
        let completion = await completeReviewedExecution(permit, in: bridge)
        XCTAssertEqual(completion, .persisted)
        let completed = try firstStoredState("completed")
        XCTAssertEqual(Set(completed.keys), ["since", "response", "acknowledged"])
        XCTAssertEqual(completed["acknowledged"] as? Bool, false)
        XCTAssertEqual(
            completed["response"] as? Data,
            ExtensionBridge.payloadData(response.json, options: [.sortedKeys])
        )
        bridge = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .found(let terminal) = await bridge.load(handle: handle) else {
            return XCTFail("Expected completed response after restart")
        }
        XCTAssertEqual(terminal.phase, .responded)
        XCTAssertNil(terminal.request)
        XCTAssertNil(terminal.nativeApproval)
        XCTAssertNil(terminal.nativeDeliveryReceipt)
        XCTAssertNil(terminal.nativeExecutionContext)
    }

    func testStoredBodyPreservesJSONTypesUnknownFieldsAndRetryFingerprint() async throws {
        let template = try makeFixture(id: 86)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: template.ingress.canonicalData) as? [String: Any])
        let deadline = template.request.admissionDeadlineMilliseconds - 1
        raw["admissionDeadline"] = deadline
        var body = try XCTUnwrap(raw["body"] as? [String: Any])
        var object = try XCTUnwrap(body["object"] as? [String: Any])
        object["extensionData"] = [
            "flag": true,
            "number": 1,
            "fraction": 1.25,
            "largeInteger": 9_007_199_254_740_991,
            "values": [true, 1, NSNull()],
        ] as [String: Any]
        body["object"] = object
        raw["body"] = body
        let fixture = try authorityFixture(raw)
        let admitted = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil))
        bridge = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .found(let snapshot) = await bridge.load(handle: admitted.handle) else {
            return XCTFail("Expected JSON body after restart")
        }
        let request = try XCTUnwrap(snapshot.request)
        XCTAssertEqual(request.admissionDeadlineMilliseconds, deadline)
        XCTAssertEqual(try firstStoredBody("pending"), try bodyData(for: fixture.ingress))
        let replay = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil))
        XCTAssertEqual(replay.handle, admitted.handle)
        XCTAssertEqual(replay.admissionKind, .replay)

        var extensionData = try XCTUnwrap(object["extensionData"] as? [String: Any])
        extensionData["flag"] = 1
        object["extensionData"] = extensionData
        body["object"] = object
        raw["body"] = body
        let changed = try authorityFixture(raw)
        guard case .rejected = await bridge.enqueue(ingress: changed.ingress, profileIdentifier: nil) else {
            return XCTFail("A boolean changed to a number must conflict with the original attempt")
        }
    }

    @MainActor
    func testStoredPayloadPreservesDeferredMalformedBodyErrors() async throws {
        let account = WalletAccountDescriptor(
            walletID: "stored-solana-wallet", coin: .solana,
            normalizedAddress: "11111111111111111111111111111111", derivationPath: "m/44'/501'/0'/0'"
        )
        _ = try await grantAuthority(account, id: 90)
        let template = try makeFixture(id: 87)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: template.ingress.canonicalData) as? [String: Any])
        for (index, provider) in ["ethereum", "solana"].enumerated() {
            var raw = original
            raw["id"] = 87 + index
            raw["enqueueAttempt"] = attempt(for: 87 + index)
            raw["provider"] = provider
            raw["name"] = provider == "ethereum" ? "ecRecover" : "signAllTransactions"
            raw["body"] = provider == "ethereum"
                ? ["address": "", "object": NSNull()]
                : ["publicKey": account.normalizedAddress, "object": ["params": ["messages": NSNull()]]]
            let fixture = try authorityFixture(raw)
            let admitted = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil))
            guard case .found(let originalSnapshot) = await bridge.load(handle: admitted.handle),
                  let originalBinding = originalSnapshot.requestBinding,
                  case .immediate(let expected) = DappRequestProcessor().prepareWithoutWallets(originalBinding) else {
                return XCTFail("Expected the existing deferred provider error")
            }
            bridge = makeBridge(clock: { [clock = clock!] in clock.now })
            guard case .found(let snapshot) = await bridge.load(handle: admitted.handle),
                  let binding = snapshot.requestBinding,
                  case .immediate(let actual) = DappRequestProcessor().prepareWithoutWallets(binding) else {
                return XCTFail("Expected the deferred provider error after restart")
            }
            XCTAssertEqual(actual.response(for: binding.request)?.json as NSDictionary?, expected.response(for: originalBinding.request)?.json as NSDictionary?)
        }
    }

    func testStoredPayloadEnvelopeLimitIncludesRequestMetadata() async throws {
        let fixture = try makeFixture(id: 89, message: "")
        _ = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.ingress.canonicalData) as? [String: Any])
        var body = try XCTUnwrap(raw["body"] as? [String: Any])
        let bodyOverhead = try bodyData(for: fixture.ingress).count
        body["object"] = ["data": String(repeating: "x", count: ExtensionBridge.maximumPayloadBytes - bodyOverhead)]
        let oversizedBodyData = try XCTUnwrap(ExtensionBridge.payloadData(body, options: [.sortedKeys]))
        XCTAssertEqual(oversizedBodyData.count, ExtensionBridge.maximumPayloadBytes)
        raw["body"] = body
        XCTAssertTrue(WireProtocol.validate(.dappRequest, value: raw))
        XCTAssertGreaterThan(
            try XCTUnwrap(ExtensionBridge.payloadData(raw, options: [.sortedKeys])).count,
            ExtensionBridge.maximumPayloadBytes
        )
        let fingerprint = try XCTUnwrap(ExtensionBridge.correlationFingerprint(raw))
        try mutateFirstStoredRecord { record in
            var state = try XCTUnwrap(record["state"] as? [String: Any])
            var pending = try XCTUnwrap(state["pending"] as? [String: Any])
            var request = try XCTUnwrap(pending["request"] as? [String: Any])
            request["bodyData"] = oversizedBodyData
            pending["request"] = request
            state["pending"] = pending
            record["state"] = state
            record["requestFingerprint"] = fingerprint
        }
        try await assertStoredProfileUnavailableAndUnchanged()
    }

    func testStoredPayloadMaterializesSnapshotsAndRecoveryDiscovery() throws {
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { [clock = clock!] in clock.now }
        ))
        let ordinary = try makeFixture(id: 901)
        let manual = try makeManualFixture(
            id: 902,
            enqueueAttempt: attempt(for: 902),
            latestConfigurations: []
        )
        let ordinaryHandle = try accepted(store.enqueue(
            ingress: ordinary.ingress,
            profileIdentifier: nil
        )).handle
        let manualHandle = try accepted(store.enqueue(
            ingress: manual.ingress,
            profileIdentifier: nil
        )).handle

        guard case .available(let snapshots) = store.list(profileIdentifier: nil) else {
            return XCTFail("Expected validated snapshots")
        }
        XCTAssertEqual(snapshots[ordinaryHandle]?.request?.id, ordinary.request.id)
        XCTAssertEqual(snapshots[manualHandle]?.request?.id, manual.request.id)

        guard case .found(let ordinarySnapshot) = store.load(handle: ordinaryHandle) else {
            return XCTFail("Expected ordinary snapshot")
        }
        XCTAssertEqual(ordinarySnapshot.request?.id, ordinary.request.id)

        let page = try recoveryRequests(store.listRecoveryRequests(
            profileIdentifier: nil
        ))
        XCTAssertEqual(Set(page.map(\.handle)), [ordinaryHandle, manualHandle])
        XCTAssertEqual(page.filter(\.manual).map(\.handle), [manualHandle])
        guard case .found(let manualSnapshot) = store.load(handle: manualHandle) else {
            return XCTFail("Expected manual switch snapshot")
        }
        XCTAssertEqual(manualSnapshot.request?.id, manual.request.id)

        let coalescing = try makeManualFixture(
            id: 903,
            enqueueAttempt: attempt(for: 903),
            latestConfigurations: []
        )
        let admission = try accepted(store.enqueue(
            ingress: coalescing.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(admission.handle, manualHandle)
        XCTAssertEqual(admission.admissionKind, .coalesced)
    }

    func testStoredPayloadObservesChangesFromAnotherStore() throws {
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { [clock = clock!] in clock.now }
        ))
        let otherStore = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { [clock = clock!] in clock.now }
        ))
        let first = try makeFixture(id: 904)
        let handle = try accepted(store.enqueue(
            ingress: first.ingress,
            profileIdentifier: nil
        )).handle
        guard case .found = store.load(handle: handle) else {
            return XCTFail("Expected initial request")
        }
        guard case .found = store.load(handle: handle) else {
            return XCTFail("Expected a fresh read of the same request")
        }

        let second = try makeFixture(id: 905)
        _ = try accepted(otherStore.enqueue(ingress: second.ingress, profileIdentifier: nil))
        XCTAssertEqual(otherStore.completeImmediate(
            handle: handle,
            resolution: immediateResolution(for: first.request)
        ), .persisted)
        guard case .found(let completed) = store.load(handle: handle) else {
            return XCTFail("Expected the other store's completion")
        }
        XCTAssertEqual(completed.phase, .responded)
        XCTAssertNil(completed.request)

        let persisted = try Data(contentsOf: defaultProfileURL)
        try Data("corrupt profile".utf8).write(to: defaultProfileURL)
        guard case .unavailable = store.load(handle: handle) else {
            return XCTFail("Expected corruption to be observed on the next operation")
        }
        try persisted.write(to: defaultProfileURL)
        guard case .found = store.load(handle: handle) else {
            return XCTFail("Expected a fresh read after the profile is restored")
        }
        try FileManager.default.removeItem(at: defaultProfileURL)
        guard case .missing = store.load(handle: handle) else {
            return XCTFail("Expected removal to be observed on the next operation")
        }
    }

    func testCachedProfileStillChecksExpectedProfileIdentity() throws {
        let profileIdentifier = UUID()
        let profile = ExtensionRequestProfile.State(
            profileIdentifier: profileIdentifier, authorityEpoch: UUID(),
            revocationCursor: .init(epoch: UUID(), sequence: 0)
        )
        let data = try ExtensionRequestProfileCodec.encode(profile)
        var codec = ExtensionRequestProfileCodec()
        for expectedIdentifier in [profileIdentifier, profileIdentifier, nil, UUID(), profileIdentifier] {
            let decoded = codec.decodeProfile(
                data, expectedIdentifier: expectedIdentifier, recoverAuthority: true, now: clock.now
            )
            XCTAssertEqual(decoded != nil, expectedIdentifier == profileIdentifier)
        }
    }

    @MainActor
    func testCachedProfileStillExpiresRequestsAndRecoversReleasedBroadcasts() async throws {
        let pending = try makeFixture(id: 906)
        let pendingHandle = try accepted(await bridge.enqueue(ingress: pending.ingress, profileIdentifier: nil)).handle
        let execution = try await makeExecutableNativePermit(id: 907)
        let checkpoint = await prepareReviewedBroadcast(execution.permit)
        XCTAssertEqual(checkpoint, .persisted)
        let warmStatus = await bridge.responseStatus(
            handle: execution.handle, configurationKey: execution.request.configurationKey
        )
        XCTAssertEqual(warmStatus, .pending)
        let original = try Data(contentsOf: defaultProfileURL)

        clock.now = pending.request.admissionDeadline.addingTimeInterval(1)
        execution.permit.releaseLease()
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original)
        await bridge.performMaintenance(profileIdentifier: nil)

        let expired = try await deliveredAuthority(pendingHandle)
        XCTAssertEqual((expired.response["error"] as? [String: Any])?["code"] as? Int, 4001)
        let recovered = try await deliveredAuthority(execution.handle)
        XCTAssertTrue(NSDictionary(dictionary: recovered.response).isEqual(to: execution.permit.recoveryResponse.json))
    }

    @MainActor
    func testCanonicalBodySurvivesClaimReleaseRollbackAndBroadcast() async throws {
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { [clock = clock!] in clock.now }
        ))
        let fixture = try makeTransactionFixture(id: 906)
        let rawObject = try JSONSerialization.jsonObject(with: fixture.ingress.canonicalData)
        let originalData = try JSONSerialization.data(
            withJSONObject: rawObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        XCTAssertNotEqual(originalData, fixture.ingress.canonicalData)
        let ingress = ExtensionBridge.Ingress(
            request: fixture.request,
            canonicalData: originalData,
            fingerprint: fixture.ingress.fingerprint,
            authority: fixture.ingress.authority,
            replayOnly: false
        )
        let handle = try accepted(store.enqueue(ingress: ingress, profileIdentifier: nil)).handle
        let initialClaim = try approvalClaim(store.claim(handle: handle))
        XCTAssertEqual(try firstStoredBody("claimed"), try bodyData(for: fixture.ingress))
        XCTAssertEqual(store.abandon(claim: initialClaim), .persisted)
        XCTAssertEqual(try firstStoredBody("pending"), try bodyData(for: fixture.ingress))

        let rollbackClaim = try approvalClaim(store.claim(handle: handle))
        XCTAssertTrue(rollbackClaim.adoptForExecution())
        XCTAssertEqual(store.abandon(claim: rollbackClaim), .persisted)
        XCTAssertEqual(try firstStoredBody("pending"), try bodyData(for: fixture.ingress))

        let claim = try approvalClaim(store.claim(handle: handle))
        let permit = try await reviewedExecution(claim)
        _ = permit.recoveryResponse
        XCTAssertEqual(prepareReviewedBroadcast(permit, in: store), .persisted)
        XCTAssertEqual(try firstStoredBody("broadcastPrepared"), try bodyData(for: fixture.ingress))
        XCTAssertEqual(completeReviewedExecution(permit, in: store), .persisted)
        guard case .found(let completed) = store.load(handle: handle) else {
            return XCTFail("Expected completed snapshot")
        }
        XCTAssertNil(completed.request)
    }

    @MainActor
    func testStoredPayloadSupportsExpiryAndAbandonedExecutionRecovery() async throws {
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { [clock = clock!] in clock.now }
        ))
        for (index, state) in ["pending", "claimed", "broadcastPrepared"].enumerated() {
            let fixture = try makeTransactionFixture(id: 907 + index)
            let handle = try accepted(store.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: nil
            )).handle
            var expectedRecovery: ResponseToExtension?
            if state != "pending" {
                let claim = try approvalClaim(store.claim(handle: handle))
                if state == "broadcastPrepared" {
                    let permit = try await reviewedExecution(claim)
                    expectedRecovery = permit.recoveryResponse
                    XCTAssertEqual(prepareReviewedBroadcast(permit, in: store), .persisted)
                    permit.releaseLease()
                } else {
                    claim.releaseUnapproved()
                }
            }
            clock.now.addTimeInterval(ExtensionBridge.requestTTL)
            guard case .found(let recovered) = store.load(handle: handle) else {
                return XCTFail("Expected recovery from \(state)")
            }
            XCTAssertEqual(recovered.phase, .responded)
            XCTAssertNil(recovered.request)
            let terminal = try responseJSON(store.prepareResponseDelivery(
                handle: handle,
                configurationKey: fixture.request.configurationKey
            ))
            let expected = expectedRecovery ?? ResponseToExtension(for: fixture.request, payload: .error(.userRejected))
            XCTAssertEqual(terminal as NSDictionary, expected.json as NSDictionary)
        }
    }

    func testStoredPayloadSurvivesFailedAndAmbiguousWrites() throws {
        let failBeforeWrite = LockedTestValue(false)
        let failAfterWrite = LockedTestValue(false)
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { data, url in
                if failBeforeWrite.value { throw Failure.injectedWrite }
                try ApprovalStoreTestPersistence.write(data, url)
                if failAfterWrite.value { throw Failure.injectedWrite }
            }
        ))
        let fixture = try makeFixture(id: 910)
        let handle = try accepted(store.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        failBeforeWrite.value = true
        XCTAssertEqual(store.reject(handle: handle), .retryablePersistenceFailure)
        failBeforeWrite.value = false
        guard case .found(let pending) = store.load(handle: handle) else {
            return XCTFail("Expected the persisted pending request after a failed write")
        }
        XCTAssertEqual(pending.phase, .queued)
        XCTAssertEqual(pending.request?.id, fixture.request.id)

        failAfterWrite.value = true
        XCTAssertEqual(store.completeImmediate(
            handle: handle,
            resolution: immediateResolution(for: fixture.request)
        ), .persisted)
        failAfterWrite.value = false
        guard case .found(let completed) = store.load(handle: handle) else {
            return XCTFail("Expected completion after exact read-back recovery")
        }
        XCTAssertNil(completed.request)
    }

    func testLostEnqueueReplyDeduplicatesTheExactAttempt() async throws {
        final class WriteControl: Sendable {
            let shouldThrow = LockedTestValue(true)
            func write(_ data: Data, to url: URL) throws {
                try ApprovalStoreTestPersistence.write(data, url)
                let fail = url.pathExtension == "state" && shouldThrow.withValue { value in
                    defer { value = false }
                    return value
                }
                if fail { throw Failure.injectedWrite }
            }
        }
        let writes = WriteControl()
        bridge = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { try writes.write($0, to: $1) }
        )
        let fixture = try makeFixture(id: 2)

        let first = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let retry = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let repeated = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(first.admissionKind, .new)
        XCTAssertEqual(retry.handle, repeated.handle)
        XCTAssertEqual(first.handle, retry.handle)
        XCTAssertEqual(
            first.nativeDeliveryNonce,
            retry.nativeDeliveryNonce
        )
        XCTAssertEqual(
            retry.nativeDeliveryNonce,
            repeated.nativeDeliveryNonce
        )
        XCTAssertEqual(retry.admissionKind, .replay)
        XCTAssertEqual(repeated.admissionKind, .replay)
        guard case .available(let snapshots) = await bridge.list(
            profileIdentifier: nil
        ) else { return XCTFail("Expected list") }
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(
            snapshots[first.handle]?.nativeDeliveryNonce,
            first.nativeDeliveryNonce
        )
    }

    func testReplayOnlyRejectsMissingOrMismatchedRequests() async throws {
        let replay = try makeFixture(id: 2, replayOnly: true)
        guard case .rejected = await bridge.enqueue(
            ingress: replay.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Recovery must not admit a new request") }

        let admission = try accepted(await bridge.enqueue(
            ingress: try makeFixture(id: 2).ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(admission.admissionKind, .new)
        for (fixture, profile) in [
            (try makeFixture(id: 2, message: "0x00", replayOnly: true), nil),
            (replay, UUID()),
        ] {
            guard case .rejected = await bridge.enqueue(
                ingress: try profileFixture(fixture, profileIdentifier: profile).ingress,
                profileIdentifier: profile
            ) else { return XCTFail("Recovery must match the request and profile") }
        }
        guard case .available(let snapshots) = await bridge.list(
            profileIdentifier: nil
        ) else { return XCTFail("Expected list") }
        XCTAssertEqual(snapshots.count, 1)
    }

    func testReplayOnlyRejectsQueuedRequestsAndRecoversCompletedResponseAfterAdmissionDeadline() async throws {
        let fixture = try makeFixture(id: 2)
        let replay = try makeFixture(
            id: 2,
            replayOnly: true
        )
        let original = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        guard case .rejected = await bridge.enqueue(
            ingress: replay.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Queued unauthorized requests must not keep polling") }
        let completion = await bridge.completeImmediate(
            handle: original.handle,
            resolution: .ethereumRecoveredAddress("signed")
        )
        XCTAssertEqual(completion, .persisted)
        clock.now.addTimeInterval(ExtensionBridge.requestTTL + 1)
        bridge = makeBridge(clock: { [clock = clock!] in clock.now })

        let recovered = try accepted(await bridge.enqueue(
            ingress: replay.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(recovered.handle, original.handle)
        XCTAssertEqual(recovered.revisions, original.revisions)
        XCTAssertEqual(recovered.admissionKind, .replay)
        XCTAssertFalse(recovered.approvalRequired)
        guard case .response(let response) = await bridge.prepareResponseDelivery(
            id: fixture.request.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: recovered.handle.requestToken,
            profileIdentifier: nil
        ) else { return XCTFail("Expected the stored result") }
        XCTAssertEqual((response["response"] as? [String: Any])?["result"] as? String, "signed")
    }

    @MainActor
    func testReplayOnlyWaitsForClaimResolutionAndRecoversDroppedBroadcast() async throws {
        let fixture = try makeTransactionFixture(id: 2)
        let replay = try makeTransactionFixture(id: 2, replayOnly: true)
        let original = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let claim = try approvalClaim(await bridge.claim(handle: original.handle))
        guard case .unavailable = await bridge.enqueue(
            ingress: replay.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("An uncommitted claim must keep admission retrying") }
        let release = await bridge.abandon(claim: claim)
        XCTAssertEqual(release, .persisted)
        guard case .rejected = await bridge.enqueue(
            ingress: replay.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("A released claim must reject the unauthorized retry") }

        let nextClaim = try approvalClaim(await bridge.claim(handle: original.handle))
        let permit = try await reviewedExecution(nextClaim)
        let checkpoint = await prepareReviewedBroadcast(permit, in: bridge)
        XCTAssertEqual(checkpoint, .persisted)
        let broadcasting = try accepted(await bridge.enqueue(
            ingress: replay.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(broadcasting.handle, original.handle)
        XCTAssertTrue(broadcasting.approvalRequired)
        permit.releaseLease()

        let recovered = try accepted(await bridge.enqueue(
            ingress: replay.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(recovered.handle, original.handle)
        XCTAssertFalse(recovered.approvalRequired)
        let response = try responseJSON(await bridge.prepareResponseDelivery(
            id: fixture.request.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: recovered.handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(
            (response["error"] as? [String: Any])?["code"] as? Int,
            ProviderResponseError.transactionSubmissionUnknownCode
        )
    }

    func testReplayOnlyFlagRequiresABoolean() throws {
        let fixture = try makeFixture(id: 2)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture.ingress.canonicalData
        ) as? [String: Any])
        for value: Any in [0, 1, "true", NSNull()] {
            object["replayOnly"] = value
            guard case .invalid = ExtensionBridge.dappIngressResult(
                request: fixture.request,
                rawObject: object
            ) else { return XCTFail("Expected malformed recovery flag rejection") }
        }
    }

    func testNativeDeliveryReceiptIsIdempotentOwnedAndClearedAtCompletion() async throws {
        let fixture = try makeFixture(id: 82, name: "requestAccounts")
        let admission = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let firstRuntime = UUID()
        let secondRuntime = UUID()
        let owner = try XCTUnwrap(ExtensionBridge.NativeDeliveryOwner(
            runtimeInstanceIdentifier: firstRuntime,
            processIdentifier: 42,
            processStartDate: clock.now,
            bundleURL: URL(
                fileURLWithPath:
                    "/Applications/Big Wallet.app/Contents/Helpers/Big Wallet.app"
            ),
            marketingVersion: "1.0.99",
            buildVersion: "148"
        ))

        let firstRecord = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            owner: owner
        )
        XCTAssertEqual(firstRecord, .persisted)
        let duplicateRecord = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            owner: owner
        )
        XCTAssertEqual(duplicateRecord, .persisted)
        let conflictingRecord = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            owner: storedRequestNativeOwner(runtime: secondRuntime)
        )
        XCTAssertEqual(conflictingRecord, .ownershipLost)
        bridge = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .found(let owned) = await bridge.load(
            handle: admission.handle
        ) else { return XCTFail("Expected owned delivery") }
        XCTAssertEqual(
            owned.nativeDeliveryReceipt,
            .init(
                nativeDeliveryNonce: admission.nativeDeliveryNonce,
                owner: owner
            )
        )
        guard case .executing = await bridge.claim(handle: admission.handle) else {
            return XCTFail("Native receipt must exclude popup claims")
        }
        let conflictingClear = await bridge.clearNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: secondRuntime
        )
        XCTAssertEqual(conflictingClear, .ownershipLost)
        let clear = await bridge.clearNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime
        )
        XCTAssertEqual(clear, .persisted)
        let secondRecord = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            owner: storedRequestNativeOwner(runtime: secondRuntime)
        )
        XCTAssertEqual(secondRecord, .persisted)
        bridge = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .found(let deliveredSnapshot) = await bridge.load(
            handle: admission.handle
        ) else { return XCTFail("Expected delivery after restart") }
        XCTAssertNil(deliveredSnapshot.nativeApproval)
        XCTAssertNil(deliveredSnapshot.nativeExecutionContext)
        XCTAssertFalse(deliveredSnapshot.hasActiveExecution)
        XCTAssertEqual(
            deliveredSnapshot.nativeDeliveryReceipt?.owner.runtimeInstanceIdentifier,
            secondRuntime
        )
        guard case .claimed(let claim) = await claimDeliveredNativeExecution(
            in: bridge, handle: admission.handle, approvedAt: clock.now
        ) else { return XCTFail("Expected native claim after fresh approval") }
        XCTAssertTrue(claim.adoptForExecution())
        let completion = await bridge.complete(
            claim: claim,
            resolution: immediateResolution(for: fixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        bridge = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .found(let completed) = await bridge.load(
            handle: admission.handle
        ) else { return XCTFail("Expected completed delivery") }
        XCTAssertEqual(completed.phase, .responded)
        XCTAssertNil(completed.nativeDeliveryReceipt)
    }

    func testNativeDeliveryReceiptRequiresOwnerMetadata() throws {
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: .init(value: UUID()),
            owner: storedRequestNativeOwner(runtime: UUID())
        )
        let data = try JSONEncoder().encode(receipt)
        XCTAssertEqual(
            try JSONDecoder().decode(ExtensionBridge.NativeDeliveryReceipt.self, from: data),
            receipt
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        for owner: Any? in [nil, NSNull()] {
            object["owner"] = owner
            XCTAssertThrowsError(try JSONDecoder().decode(
                ExtensionBridge.NativeDeliveryReceipt.self,
                from: JSONSerialization.data(withJSONObject: object)
            ))
        }
    }

    func testMalformedReceiptOwnerIsUnavailableWithoutOverwriting() async throws {
        let admission = try accepted(await bridge.enqueue(
            ingress: makeFixture(id: 735).ingress,
            profileIdentifier: nil
        ))
        let recorded = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            owner: storedRequestNativeOwner(runtime: UUID())
        )
        XCTAssertEqual(recorded, .persisted)
        let original = try Data(contentsOf: defaultProfileURL)
        let invalidOwners: [Any?] = [
            nil,
            "invalid owner",
            [
                "bundlePath": "/not-an-app",
                "marketingVersion": "1.0.99",
                "buildVersion": "148",
            ],
        ]
        for owner in invalidOwners {
            try original.write(to: defaultProfileURL, options: .atomic)
            try mutateFirstStoredState("pending") { pending in
                var approval = try XCTUnwrap(pending["approval"] as? [String: Any])
                var delivered = try XCTUnwrap(approval["delivered"] as? [String: Any])
                var receipt = try XCTUnwrap(delivered["_0"] as? [String: Any])
                receipt["owner"] = owner
                delivered["_0"] = receipt
                approval["delivered"] = delivered
                pending["approval"] = approval
            }
            try await assertStoredProfileUnavailableAndUnchanged()
        }
    }

    func testNativeDeliveryReceiptClearsWhenPendingRequestExpires() async throws {
        let deadline = clock.now.addingTimeInterval(30)
        let fixture = try makeFixture(
            id: 83,
            admissionDeadline: deadline
        )
        let admission = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let recorded = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            owner: storedRequestNativeOwner(runtime: UUID())
        )
        XCTAssertEqual(recorded, .persisted)

        clock.now = deadline
        guard case .found(let expired) = await bridge.load(
            handle: admission.handle
        ) else { return XCTFail("Expected retained expiration response") }
        XCTAssertEqual(expired.phase, .responded)
        XCTAssertNil(expired.nativeDeliveryReceipt)
    }

    func testNativeDeliveryReceiptVerifiesAmbiguousWrites() async throws {
        final class WriteControl: Sendable {
            let throwsRemaining = LockedTestValue(0)

            func write(_ data: Data, to url: URL) throws {
                try ApprovalStoreTestPersistence.write(data, url)
                let fail = url.pathExtension == "state" && throwsRemaining.withValue { remaining in
                    guard remaining > 0 else { return false }
                    remaining -= 1
                    return true
                }
                if fail { throw Failure.injectedWrite }
            }
        }
        let writes = WriteControl()
        bridge = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { try writes.write($0, to: $1) }
        )
        let admission = try accepted(await bridge.enqueue(
            ingress: try makeFixture(id: 84).ingress,
            profileIdentifier: nil
        ))
        let runtime = UUID()

        writes.throwsRemaining.value = 1
        let recorded = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            owner: storedRequestNativeOwner(runtime: runtime)
        )
        XCTAssertEqual(recorded, .persisted)

        writes.throwsRemaining.value = 1
        let cleared = await bridge.clearNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtime
        )
        XCTAssertEqual(cleared, .persisted)
        guard case .found(let snapshot) = await bridge.load(
            handle: admission.handle
        ) else { return XCTFail("Expected retained admission") }
        XCTAssertNil(snapshot.nativeDeliveryReceipt)
    }

    func testNativeDeliveryOwnerFencesMutations() async throws {
        let firstRuntime = UUID()
        let wrongRuntime = UUID()
        let wrongNonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())

        let claimFixture = try makeFixture(id: 85, name: "requestAccounts")
        let claimAdmission = try accepted(await bridge.enqueue(
            ingress: claimFixture.ingress,
            profileIdentifier: nil
        ))
        let unownedClaimConsent = try await nativeConsent(
            handle: claimAdmission.handle, approvedAt: clock.now,
            receipt: .init(nativeDeliveryNonce: claimAdmission.nativeDeliveryNonce, owner: storedRequestNativeOwner(runtime: firstRuntime))
        )
        let unownedClaim = await bridge.claimNativeExecution(consent: unownedClaimConsent)
        XCTAssertEqual(unownedClaim, .ownershipLost)
        let recordedClaim = await bridge.recordNativeDeliveryReceipt(
            handle: claimAdmission.handle,
            nativeDeliveryNonce: claimAdmission.nativeDeliveryNonce,
            owner: storedRequestNativeOwner(runtime: firstRuntime)
        )
        XCTAssertEqual(recordedClaim, .persisted)
        let wrongNonceClaimConsent = try await nativeConsent(
            handle: claimAdmission.handle, approvedAt: clock.now,
            receipt: .init(nativeDeliveryNonce: wrongNonce, owner: storedRequestNativeOwner(runtime: firstRuntime))
        )
        let wrongNonceClaim = await bridge.claimNativeExecution(consent: wrongNonceClaimConsent)
        XCTAssertEqual(wrongNonceClaim, .ownershipLost)
        let wrongOwnerClaimConsent = try await nativeConsent(
            handle: claimAdmission.handle, approvedAt: clock.now,
            receipt: .init(nativeDeliveryNonce: claimAdmission.nativeDeliveryNonce, owner: storedRequestNativeOwner(runtime: wrongRuntime))
        )
        let wrongOwnerClaim = await bridge.claimNativeExecution(consent: wrongOwnerClaimConsent)
        XCTAssertEqual(wrongOwnerClaim, .ownershipLost)
        let claimResultConsent = try await nativeConsent(
            handle: claimAdmission.handle, approvedAt: clock.now,
            receipt: .init(nativeDeliveryNonce: claimAdmission.nativeDeliveryNonce, owner: storedRequestNativeOwner(runtime: firstRuntime))
        )
        let claimResult = await bridge.claimNativeExecution(consent: claimResultConsent)
        guard case .claimed(let nativeClaim) = claimResult else { return XCTFail("Expected native claim") }
        defer { nativeClaim.releaseUnapproved() }
        guard case .found(let claimedSnapshot) = await bridge.load(
            handle: claimAdmission.handle
        ) else { return XCTFail("Expected claimed execution") }
        XCTAssertNotNil(claimedSnapshot.nativeApproval)
        XCTAssertEqual(
            claimedSnapshot.nativeDeliveryReceipt?.owner.runtimeInstanceIdentifier,
            firstRuntime
        )

        let completeFixture = try makeFixture(id: 86)
        let completeAdmission = try accepted(await bridge.enqueue(
            ingress: completeFixture.ingress,
            profileIdentifier: nil
        ))
        let recordedCompletion = await bridge.recordNativeDeliveryReceipt(
            handle: completeAdmission.handle,
            nativeDeliveryNonce: completeAdmission.nativeDeliveryNonce,
            owner: storedRequestNativeOwner(runtime: firstRuntime)
        )
        XCTAssertEqual(recordedCompletion, .persisted)
        let ownerlessCompletion = await bridge.completeImmediate(
            handle: completeAdmission.handle,
            resolution: immediateResolution(for: completeFixture.request)
        )
        XCTAssertEqual(ownerlessCompletion, .ownershipLost)
        let wrongNonceCompletion = await bridge.completeNativeImmediate(
            handle: completeAdmission.handle,
            nativeDeliveryNonce: wrongNonce,
            runtimeInstanceIdentifier: firstRuntime,
            resolution: immediateResolution(for: completeFixture.request)
        )
        XCTAssertEqual(wrongNonceCompletion, .ownershipLost)
        let wrongOwnerCompletion = await bridge.completeNativeImmediate(
            handle: completeAdmission.handle,
            nativeDeliveryNonce: completeAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: wrongRuntime,
            resolution: immediateResolution(for: completeFixture.request)
        )
        XCTAssertEqual(wrongOwnerCompletion, .ownershipLost)
        let completion = await bridge.completeNativeImmediate(
            handle: completeAdmission.handle,
            nativeDeliveryNonce: completeAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime,
            resolution: immediateResolution(for: completeFixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        guard case .found(let completedSnapshot) = await bridge.load(
            handle: completeAdmission.handle
        ) else { return XCTFail("Expected completed delivery") }
        XCTAssertEqual(completedSnapshot.phase, .responded)
        XCTAssertNil(completedSnapshot.nativeDeliveryReceipt)

        let rejectFixture = try makeFixture(id: 87)
        let rejectAdmission = try accepted(await bridge.enqueue(
            ingress: rejectFixture.ingress,
            profileIdentifier: nil
        ))
        let recordedRejection = await bridge.recordNativeDeliveryReceipt(
            handle: rejectAdmission.handle,
            nativeDeliveryNonce: rejectAdmission.nativeDeliveryNonce,
            owner: storedRequestNativeOwner(runtime: firstRuntime)
        )
        XCTAssertEqual(recordedRejection, .persisted)
        let ownerlessRejection = await bridge.reject(
            handle: rejectAdmission.handle
        )
        XCTAssertEqual(ownerlessRejection, .ownershipLost)
        let wrongNonceRejection = await bridge.rejectNativeDelivery(
            handle: rejectAdmission.handle,
            nativeDeliveryNonce: wrongNonce,
            runtimeInstanceIdentifier: firstRuntime
        )
        XCTAssertEqual(wrongNonceRejection, .ownershipLost)
        let wrongOwnerRejection = await bridge.rejectNativeDelivery(
            handle: rejectAdmission.handle,
            nativeDeliveryNonce: rejectAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: wrongRuntime
        )
        XCTAssertEqual(wrongOwnerRejection, .ownershipLost)
        let rejection = await bridge.rejectNativeDelivery(
            handle: rejectAdmission.handle,
            nativeDeliveryNonce: rejectAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime
        )
        XCTAssertEqual(rejection, .persisted)
        guard case .found(let rejectedSnapshot) = await bridge.load(
            handle: rejectAdmission.handle
        ) else { return XCTFail("Expected rejected delivery") }
        XCTAssertEqual(rejectedSnapshot.phase, .responded)
        XCTAssertNil(rejectedSnapshot.nativeDeliveryReceipt)
    }

    func testNativeDeliveryOwnerMutationsVerifyAmbiguousWrites() async throws {
        final class WriteControl: Sendable {
            let throwsRemaining = LockedTestValue(0)

            func write(_ data: Data, to url: URL) throws {
                try ApprovalStoreTestPersistence.write(data, url)
                let fail = url.pathExtension == "state" && throwsRemaining.withValue { remaining in
                    guard remaining > 0 else { return false }
                    remaining -= 1
                    return true
                }
                if fail { throw Failure.injectedWrite }
            }
        }
        let writes = WriteControl()
        bridge = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { try writes.write($0, to: $1) }
        )
        let firstRuntime = UUID()

        let claimFixture = try makeFixture(id: 88, name: "requestAccounts")
        let claimAdmission = try accepted(await bridge.enqueue(
            ingress: claimFixture.ingress,
            profileIdentifier: nil
        ))
        let claimReceipt = await bridge.recordNativeDeliveryReceipt(
            handle: claimAdmission.handle,
            nativeDeliveryNonce: claimAdmission.nativeDeliveryNonce,
            owner: storedRequestNativeOwner(runtime: firstRuntime)
        )
        XCTAssertEqual(claimReceipt, .persisted)
        writes.throwsRemaining.value = 1
        let claimResultConsent = try await nativeConsent(
            handle: claimAdmission.handle, approvedAt: clock.now,
            receipt: .init(nativeDeliveryNonce: claimAdmission.nativeDeliveryNonce, owner: storedRequestNativeOwner(runtime: firstRuntime))
        )
        let claimResult = await bridge.claimNativeExecution(consent: claimResultConsent)
        XCTAssertEqual(claimResult, .unavailable)
        let recovered = try responseJSON(await bridge.prepareResponseDelivery(
            id: claimAdmission.handle.id,
            configurationKey: claimFixture.request.configurationKey,
            requestToken: claimAdmission.handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual((recovered["error"] as? [String: Any])?["message"] as? String, Strings.approvalInterrupted)

        let completeFixture = try makeFixture(id: 89)
        let completeAdmission = try accepted(await bridge.enqueue(
            ingress: completeFixture.ingress,
            profileIdentifier: nil
        ))
        let completeReceipt = await bridge.recordNativeDeliveryReceipt(
            handle: completeAdmission.handle,
            nativeDeliveryNonce: completeAdmission.nativeDeliveryNonce,
            owner: storedRequestNativeOwner(runtime: firstRuntime)
        )
        XCTAssertEqual(completeReceipt, .persisted)
        writes.throwsRemaining.value = 1
        let completed = await bridge.completeNativeImmediate(
            handle: completeAdmission.handle,
            nativeDeliveryNonce: completeAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime,
            resolution: immediateResolution(for: completeFixture.request)
        )
        XCTAssertEqual(completed, .persisted)

        let rejectFixture = try makeFixture(id: 91)
        let rejectAdmission = try accepted(await bridge.enqueue(
            ingress: rejectFixture.ingress,
            profileIdentifier: nil
        ))
        let rejectReceipt = await bridge.recordNativeDeliveryReceipt(
            handle: rejectAdmission.handle,
            nativeDeliveryNonce: rejectAdmission.nativeDeliveryNonce,
            owner: storedRequestNativeOwner(runtime: firstRuntime)
        )
        XCTAssertEqual(rejectReceipt, .persisted)
        writes.throwsRemaining.value = 1
        let rejected = await bridge.rejectNativeDelivery(
            handle: rejectAdmission.handle,
            nativeDeliveryNonce: rejectAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime
        )
        XCTAssertEqual(rejected, .persisted)

    }

    func testExpiredFirstArrivalDoesNotPersist() async throws {
        let fixture = try makeFixture(
            id: 90,
            admissionDeadline: clock.now
        )

        guard case .expired = await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected expired admission") }
        guard case .available(let snapshots) = await bridge.list(
            profileIdentifier: nil
        ) else { return XCTFail("Expected available profile") }
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testAdmissionDeadlineDispositionUsesOneBoundedWindow() {
        XCTAssertEqual(
            ExtensionBridge.admissionDeadlineDisposition(clock.now, now: clock.now),
            .expired
        )
        XCTAssertEqual(
            ExtensionBridge.admissionDeadlineDisposition(
                clock.now.addingTimeInterval(ExtensionBridge.requestTTL),
                now: clock.now
            ),
            .admissible
        )
        XCTAssertEqual(
            ExtensionBridge.admissionDeadlineDisposition(
                clock.now.addingTimeInterval(
                    ExtensionBridge.requestTTL +
                        ExtensionBridge.admissionDeadlineFutureSkew + 1
                ),
                now: clock.now
            ),
            .invalid
        )
    }

    func testAdmissionDeadlineRequiresPositiveSafeIntegerMilliseconds() throws {
        let fixture = try makeFixture(id: 93)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: fixture.ingress.canonicalData
            ) as? [String: Any]
        )

        for invalid in [
            0,
            9_007_199_254_740_992,
            true,
            1.5,
        ] as [Any] {
            object["admissionDeadline"] = invalid
            XCTAssertNil(SafariRequest(json: object))
        }
    }

    func testAdmissionDeadlineCannotChangeAcrossRetries() async throws {
        let attempt = String(repeating: "d", count: 32)
        let original = try makeFixture(id: 91, enqueueAttempt: attempt)
        let changed = try makeFixture(
            id: 91,
            enqueueAttempt: attempt,
            admissionDeadline: clock.now.addingTimeInterval(
                ExtensionBridge.requestTTL - 1
            )
        )
        _ = try accepted(await bridge.enqueue(
            ingress: original.ingress,
            profileIdentifier: nil
        ))

        guard case .rejected = await bridge.enqueue(
            ingress: changed.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected deadline mismatch rejection") }
    }

    func testExcessivelyFutureAdmissionDeadlineIsRejected() async throws {
        let fixture = try makeFixture(
            id: 92,
            admissionDeadline: clock.now.addingTimeInterval(
                ExtensionBridge.requestTTL + 61
            )
        )

        guard case .rejected = await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected future deadline rejection") }
    }

    func testAttemptReuseWithDifferentPayloadFailsClosed() async throws {
        let attempt = String(repeating: "1", count: 32)
        let original = try makeFixture(id: 3, enqueueAttempt: attempt, message: "0x01")
        let changed = try makeFixture(id: 3, enqueueAttempt: attempt, message: "0x02")
        _ = try accepted(await bridge.enqueue(
            ingress: original.ingress,
            profileIdentifier: nil
        ))
        guard case .rejected = await bridge.enqueue(
            ingress: changed.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected conflicting retry rejection") }
    }

    func testAttemptRetryReturnsOriginalRevisionsAcrossRevisionDrift() async throws {
        let attempt = String(repeating: "2", count: 32)
        let original = try makeFixture(
            id: 4,
            name: "requestAccounts",
            enqueueAttempt: attempt
        )
        var changedAuthority = try XCTUnwrap(JSONSerialization.jsonObject(with: original.ingress.canonicalData) as? [String: Any])
        changedAuthority["authority"] = ["context": original.ingress.authority.context, "revisions": ["ethereum": 1, "solana": 0]]
        let changedRevisions = try authorityFixture(changedAuthority)
        let admitted = try accepted(await bridge.enqueue(
            ingress: original.ingress,
            profileIdentifier: nil
        ))
        let retry = try accepted(await bridge.enqueue(
            ingress: original.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(admitted.admissionKind, .new)
        XCTAssertEqual(retry.admissionKind, .replay)
        XCTAssertEqual(retry.handle, admitted.handle)
        XCTAssertEqual(retry.revisions, admitted.revisions)
        guard case .found(let stored) = await bridge.load(handle: admitted.handle) else {
            return XCTFail("Expected stored request")
        }
        XCTAssertEqual(stored.revisions, admitted.revisions)
        let revisionRetry = try accepted(await bridge.enqueue(
            ingress: changedRevisions.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(revisionRetry.admissionKind, .replay)
        XCTAssertEqual(revisionRetry.handle, admitted.handle)
        XCTAssertEqual(revisionRetry.revisions, admitted.revisions)
        XCTAssertEqual(admitted.revisions.ethereum, 0)
    }

    func testStoredBodyFingerprintMismatchFailsClosed() async throws {
        _ = try accepted(await bridge.enqueue(
            ingress: try makeFixture(id: 5, name: "requestAccounts").ingress,
            profileIdentifier: nil
        ))
        try mutateFirstStoredRecord { record in
            var state = try XCTUnwrap(record["state"] as? [String: Any])
            var pending = try XCTUnwrap(state["pending"] as? [String: Any])
            var request = try XCTUnwrap(pending["request"] as? [String: Any])
            request["bodyData"] = try JSONSerialization.data(withJSONObject: ["address": "", "unexpected": true], options: [.sortedKeys])
            pending["request"] = request
            state["pending"] = pending
            record["state"] = state
        }

        guard case .unavailable = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected changed body fingerprint to fail closed")
        }
    }

    func testManualSwitchReplayKeepsOriginalBodyAcrossConfigurationDrift() async throws {
        let attempt = String(repeating: "e", count: 32)
        let original = try makeManualFixture(
            id: 405,
            enqueueAttempt: attempt,
            latestConfigurations: [[
                "provider": "ethereum",
                "chainId": "0x1",
                "results": ["0x0000000000000000000000000000000000000001"],
            ]]
        )
        let drifted = try makeManualFixture(
            id: 405,
            enqueueAttempt: attempt,
            latestConfigurations: []
        )

        let admitted = try accepted(await bridge.enqueue(
            ingress: original.ingress,
            profileIdentifier: nil
        ))
        let replay = try accepted(await bridge.enqueue(
            ingress: drifted.ingress,
            profileIdentifier: nil
        ))

        XCTAssertEqual(admitted.admissionKind, .new)
        XCTAssertEqual(replay.admissionKind, .replay)
        XCTAssertEqual(replay.handle, admitted.handle)
        guard case .found(let stored) = await bridge.load(
            handle: admitted.handle
        ), case .unknown(let body)? = stored.request?.body else {
            return XCTFail("Expected original manual switch")
        }
        XCTAssertEqual(body.providerConfigurations.count, 1)
    }

    func testConcurrentManualSwitchAttemptsCoalesceAcrossStoreInstances() async throws {
        let first = try makeManualFixture(
            id: 410,
            enqueueAttempt: attempt(for: 410),
            latestConfigurations: []
        )
        let second = try makeManualFixture(
            id: 411,
            enqueueAttempt: attempt(for: 411),
            latestConfigurations: []
        )
        let firstBridge = try XCTUnwrap(bridge)
        let now = clock.now
        let secondBridge = makeBridge(clock: { now })
        async let firstResult = firstBridge.enqueue(
            ingress: first.ingress,
            profileIdentifier: nil
        )
        async let secondResult = secondBridge.enqueue(
            ingress: second.ingress,
            profileIdentifier: nil
        )
        let admissions = try await [accepted(firstResult), accepted(secondResult)]
        XCTAssertEqual(admissions[0].handle, admissions[1].handle)
        XCTAssertEqual(admissions.filter { $0.admissionKind == .new }.count, 1)
        XCTAssertEqual(admissions.filter { $0.admissionKind == .coalesced }.count, 1)
        guard case .available(let snapshots) = await bridge.list(
            profileIdentifier: nil
        ) else { return XCTFail("Expected native switch") }
        XCTAssertEqual(snapshots.count, 1)
    }

    func testManualSwitchCoalescingRetainsCanonicalIdentityAndOriginalRevisions() async throws {
        let original = try makeManualFixture(
            id: 412,
            enqueueAttempt: attempt(for: 412),
            latestConfigurations: [[
                "provider": "ethereum",
                "chainId": "0x1",
                "results": ["0x0000000000000000000000000000000000000001"],
            ]]
        )
        let first = try accepted(await bridge.enqueue(
            ingress: original.ingress,
            profileIdentifier: nil
        ))
        let next = try makeManualFixture(
            id: 413,
            enqueueAttempt: attempt(for: 413),
            latestConfigurations: []
        )
        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        let resumed = try accepted(await observer.enqueue(
            ingress: next.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(resumed.admissionKind, .coalesced)
        XCTAssertEqual(resumed.handle, first.handle)
        XCTAssertEqual(resumed.nativeDeliveryNonce, first.nativeDeliveryNonce)
        XCTAssertEqual(resumed.revisions, first.revisions)
        XCTAssertTrue(resumed.approvalRequired)
        guard case .found(let snapshot) = await observer.load(handle: resumed.handle),
              case .unknown(let body)? = snapshot.request?.body else {
            return XCTFail("Expected original switch request")
        }
        XCTAssertEqual(snapshot.enqueueAttempt, original.request.enqueueAttempt)
        XCTAssertEqual(body.providerConfigurations.count, 1)

        let mismatchedAttempt = try makeManualFixture(
            id: 414,
            enqueueAttempt: original.request.enqueueAttempt,
            latestConfigurations: []
        )
        guard case .rejected = await observer.enqueue(
            ingress: mismatchedAttempt.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Exact-attempt mismatches must still be rejected") }
    }

    func testCompletedManualSwitchCoalescesUntilItsResponseIsAcknowledged() async throws {
        let original = try makeManualFixture(
            id: 415,
            enqueueAttempt: attempt(for: 415),
            latestConfigurations: []
        )
        let first = try accepted(await bridge.enqueue(
            ingress: original.ingress,
            profileIdentifier: nil
        ))
        let completion = await bridge.completeImmediate(handle: first.handle, resolution: .failure(.userRejected))
        XCTAssertEqual(completion, .persisted)
        let next = try makeManualFixture(
            id: 416,
            enqueueAttempt: attempt(for: 416),
            latestConfigurations: []
        )
        let recovered = try accepted(await bridge.enqueue(
            ingress: next.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(recovered.admissionKind, .coalesced)
        XCTAssertEqual(recovered.handle, first.handle)
        XCTAssertEqual(recovered.revisions, first.revisions)
        XCTAssertFalse(recovered.approvalRequired)
        let acknowledgement = await bridge.acknowledgeResponse(
            handle: recovered.handle,
            configurationKey: original.request.configurationKey
        )
        XCTAssertEqual(acknowledgement, .persisted)
        let fresh = try accepted(await bridge.enqueue(
            ingress: next.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(fresh.admissionKind, .new)
        XCTAssertEqual(fresh.handle.id, next.request.id)
        XCTAssertNotEqual(fresh.handle, first.handle)
    }

    func testManualSwitchCoalescingIsScopedToProfileAndOrigin() async throws {
        let first = try makeManualFixture(
            id: 417,
            enqueueAttempt: attempt(for: 417),
            latestConfigurations: []
        )
        let original = try accepted(await bridge.enqueue(
            ingress: first.ingress,
            profileIdentifier: nil
        ))
        let otherIdentifier = UUID()
        let otherProfile = try accepted(await bridge.enqueue(
            ingress: try profileFixture(first, profileIdentifier: otherIdentifier).ingress,
            profileIdentifier: otherIdentifier
        ))
        XCTAssertEqual(otherProfile.admissionKind, .new)
        XCTAssertNotEqual(otherProfile.handle, original.handle)

        let http = try makeManualFixture(
            id: 418,
            enqueueAttempt: attempt(for: 418),
            latestConfigurations: [],
            configurationKey: "http://wallet.example"
        )
        let otherOrigin = try accepted(await bridge.enqueue(
            ingress: http.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(otherOrigin.admissionKind, .new)
        XCTAssertNotEqual(otherOrigin.handle, original.handle)

        for id in 419...420 {
            let ordinary = try accepted(await bridge.enqueue(
                ingress: try makeFixture(id: id).ingress,
                profileIdentifier: nil
            ))
            XCTAssertEqual(ordinary.admissionKind, .new)
            XCTAssertEqual(ordinary.handle.id, id)
        }
    }

    func testExpiredNewManualIntentDoesNotCoalesceWithExistingWork() async throws {
        let original = try makeManualFixture(
            id: 421,
            enqueueAttempt: attempt(for: 421),
            latestConfigurations: []
        )
        _ = try accepted(await bridge.enqueue(
            ingress: original.ingress,
            profileIdentifier: nil
        ))
        let expired = try makeManualFixture(
            id: 422,
            enqueueAttempt: attempt(for: 422),
            latestConfigurations: [],
            admissionDeadline: clock.now.addingTimeInterval(-1)
        )
        guard case .expired = await bridge.enqueue(
            ingress: expired.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expired new intent must not acquire a stored handle") }
    }

    func testRecoveryDiscoveryDescribesStoredStatesAndRequiresExactIdentity()
        async throws {
        let pending = try makeManualFixture(
            id: 430,
            enqueueAttempt: attempt(for: 430),
            latestConfigurations: []
        )
        let pendingHandle = try accepted(await bridge.enqueue(
            ingress: pending.ingress,
            profileIdentifier: nil
        )).handle
        let approved = try makeManualFixture(
            id: 431,
            enqueueAttempt: attempt(for: 431),
            latestConfigurations: [],
            host: "approved.example",
            configurationKey: "https://approved.example"
        )
        let approvedHandle = try accepted(await bridge.enqueue(
            ingress: approved.ingress,
            profileIdentifier: nil
        )).handle
        let delivered = try await recordNativeDelivery(handle: approvedHandle)
        XCTAssertEqual(delivered, .persisted)
        guard case .claimed(let nativeClaim) = await claimDeliveredNativeExecution(
            in: bridge, handle: approvedHandle, approvedAt: clock.now
        ) else { return XCTFail("Expected native claim") }
        defer { nativeClaim.releaseUnapproved() }
        let completed = try makeManualFixture(
            id: 432,
            enqueueAttempt: attempt(for: 432),
            latestConfigurations: [],
            host: "completed.example",
            configurationKey: "https://completed.example"
        )
        let completedHandle = try accepted(await bridge.enqueue(
            ingress: completed.ingress,
            profileIdentifier: nil
        )).handle
        let completion = await bridge.completeImmediate(handle: completedHandle, resolution: .failure(.userRejected))
        XCTAssertEqual(completion, .persisted)
        let ordinary = try accepted(await bridge.enqueue(
            ingress: try makeFixture(id: 433).ingress,
            profileIdentifier: nil
        )).handle
        let foreignProfile = UUID()
        let foreign = try accepted(await bridge.enqueue(
            ingress: try profileFixture(pending, profileIdentifier: foreignProfile).ingress,
            profileIdentifier: foreignProfile
        )).handle

        let page = try recoveryRequests(await bridge.listRecoveryRequests(
            profileIdentifier: nil
        ))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: page.map {
            ($0.handle, $0.state)
        }), [pendingHandle: .pending, approvedHandle: .approved,
             completedHandle: .completed, ordinary: .pending])
        XCTAssertEqual(Set(page.filter(\.manual).map(\.handle)), [
            pendingHandle, approvedHandle, completedHandle,
        ])
        for request in page {
            XCTAssertEqual(Set(request.json.keys), [
                "id", "configurationKey", "requestToken", "manual", "state",
            ])
        }
        let pendingDescriptor = try XCTUnwrap(page.first { $0.handle == pendingHandle })
        XCTAssertEqual(pendingDescriptor.configurationKey, pending.request.configurationKey)
        guard case .found(let completedSnapshot) = await bridge.load(handle: completedHandle) else {
            return XCTFail("Expected completed switch snapshot")
        }
        XCTAssertNil(completedSnapshot.request)
        XCTAssertEqual(completedSnapshot.phase, .responded)

        for (handle, origin) in [
            (pendingHandle, "https://other.example"),
            (ExtensionBridge.Handle(
                id: foreign.id,
                token: foreign.token,
                profileIdentifier: nil
            ), pending.request.configurationKey),
        ] {
            guard case .missing = await bridge.responseStatus(
                handle: handle,
                configurationKey: origin
            ) else { return XCTFail("Status reads must require exact origin and profile") }
        }
        let acknowledged = await bridge.acknowledgeResponse(
            handle: completedHandle,
            configurationKey: completed.request.configurationKey
        )
        XCTAssertEqual(acknowledged, .persisted)
        guard case .found(let acknowledgedSnapshot) = await bridge.load(handle: completedHandle) else {
            return XCTFail("Acknowledged responses must remain readable")
        }
        XCTAssertEqual(acknowledgedSnapshot.phase, .responded)
        let acknowledgedStatus = await bridge.responseStatus(
            handle: completedHandle,
            configurationKey: completed.request.configurationKey
        )
        XCTAssertEqual(acknowledgedStatus, .ready)
        let remaining = try recoveryRequests(await bridge.listRecoveryRequests(
            profileIdentifier: nil
        ))
        XCTAssertEqual(Set(remaining.map(\.handle)), [pendingHandle, approvedHandle, ordinary])
        let foreignPage = try recoveryRequests(await bridge.listRecoveryRequests(
            profileIdentifier: foreignProfile
        ))
        XCTAssertEqual(foreignPage.map(\.handle), [foreign])

        try Data("corrupt profile".utf8).write(to: defaultProfileURL, options: .atomic)
        guard case .unavailable = await bridge.listRecoveryRequests(profileIdentifier: nil) else {
            return XCTFail("Corrupt storage must not look like an empty recovery queue")
        }
        guard case .unavailable = await bridge.load(handle: completedHandle) else {
            return XCTFail("Corrupt storage must not look like a missing request")
        }
    }

    @MainActor
    func testManualSwitchCapacityPreservesCompletedSelectionsAndCoalescesWhenFull() async throws {
        var handles = [ExtensionBridge.Handle]()
        for id in 470..<(470 + ExtensionBridge.maximumRequests) {
            let manual = try makeManualFixture(
                id: id,
                enqueueAttempt: attempt(for: id),
                latestConfigurations: [],
                host: "wallet\(id).example",
                configurationKey: "https://wallet\(id).example"
            )
            let handle = try accepted(await bridge.enqueue(
                ingress: manual.ingress,
                profileIdentifier: nil
            )).handle
            handles.append(handle)
            let completed = try await completeApprovedSelection(handle: handle, accounts: [authorityTestAccount()])
            XCTAssertEqual(completed, .persisted)
            clock.now.addTimeInterval(0.125)
        }
        let before = try Data(contentsOf: defaultProfileURL)
        let incoming = try makeManualFixture(
            id: 490,
            enqueueAttempt: attempt(for: 490),
            latestConfigurations: [],
            host: "next.example",
            configurationKey: "https://next.example"
        )
        guard case .manualSwitchCapacityReached = await bridge.enqueue(
            ingress: incoming.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("A full manual-switch inbox must reject new work") }
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), before)
        let coalesced = try makeManualFixture(
            id: 491,
            enqueueAttempt: attempt(for: 491),
            latestConfigurations: [],
            host: "wallet470.example",
            configurationKey: "https://wallet470.example"
        )
        let replay = try accepted(await bridge.enqueue(
            ingress: coalesced.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(replay.handle, handles[0])
        XCTAssertEqual(replay.admissionKind, .coalesced)
        let requests = try recoveryRequests(await bridge.listRecoveryRequests(profileIdentifier: nil)).filter(\.manual)
        XCTAssertEqual(Set(requests.map(\.handle)), Set(handles))
        XCTAssertTrue(requests.allSatisfy { $0.state == .completed })
        let acknowledged = await bridge.acknowledgeResponse(
            handle: handles[0], configurationKey: "https://wallet470.example"
        )
        XCTAssertEqual(acknowledged, .persisted)
        _ = try accepted(await bridge.enqueue(ingress: incoming.ingress, profileIdentifier: nil))
    }

    func testPendingManualSwitchesReachCapacityBeforeGenericActiveLimit() async throws {
        for id in 800..<809 {
            let manual = try makeManualFixture(
                id: id,
                enqueueAttempt: attempt(for: id),
                latestConfigurations: [],
                host: "pending\(id).example",
                configurationKey: "https://pending\(id).example"
            )
            let result = await bridge.enqueue(ingress: manual.ingress, profileIdentifier: nil)
            if id < 808 {
                _ = try accepted(result)
            } else {
                guard case .manualSwitchCapacityReached = result else {
                    return XCTFail("The ninth manual switch must report capacity")
                }
            }
        }
    }

    @MainActor
    func testManualSwitchCompletionSurvivesAdmissionBytePressure() async throws {
        let manual = try makeManualFixture(
            id: 810,
            enqueueAttempt: attempt(for: 810),
            latestConfigurations: []
        )
        let handle = try accepted(await bridge.enqueue(ingress: manual.ingress, profileIdentifier: nil)).handle
        let completed = try await completeApprovedSelection(handle: handle, accounts: [authorityTestAccount()])
        XCTAssertEqual(completed, .persisted)
        clock.now.addTimeInterval(0.125)
        let ordinary = try await fillCompletedByteCapacity(startingID: 100)
        clock.now.addTimeInterval(ExtensionBridge.requestTTL + ExtensionBridge.admissionDeadlineFutureSkew)
        _ = try accepted(await bridge.enqueue(
            ingress: makeFixture(id: 1000, host: "new.example").ingress,
            profileIdentifier: nil
        ))
        guard case .missing = await bridge.load(handle: ordinary[0].handle) else {
            return XCTFail("The test must exercise completed-record eviction")
        }
        guard case .found(let retained) = await bridge.load(handle: handle) else {
            return XCTFail("An unacknowledged selection must survive admission pressure")
        }
        XCTAssertEqual(retained.phase, .responded)
    }

    func testAuthorityOriginLengthIsBoundedBeforeAllocatingRows() async throws {
        let origin = "file:///tmp/" + String(repeating: "a", count: 4_096)
        guard case .unavailable = await bridge.configurationSnapshot(configurationKey: origin, profileIdentifier: nil) else {
            return XCTFail("Oversized origin must not allocate authority state")
        }
        let fixture = try makeFixture(id: 500)
        XCTAssertEqual((try storedProfile()["origins"] as? [String: Any])?.count, 0)
        XCTAssertEqual(fixture.ingress.authority.revisions.ethereum, 0)
    }

    func testCompletedRecordWithInvalidRevisionsFailsClosed() async throws {
        let fixture = try makeFixture(id: 6)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let completion = await bridge.completeImmediate(
            handle: handle,
            resolution: immediateResolution(for: fixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        try mutateFirstStoredRecord { record in
            var authority = try XCTUnwrap(record["authority"] as? [String: Any])
            authority["revisions"] = ["ethereum": -1, "solana": 0]
            record["authority"] = authority
        }

        guard case .unavailable = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected invalid completed revisions to fail closed")
        }
        guard case .unavailable = await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected invalid completed retry to fail closed") }
    }

    func testSchemefulOriginsHaveIndependentCapacity() async throws {
        for id in 200..<204 {
            _ = try accepted(await bridge.enqueue(
                ingress: try makeFixture(
                    id: id,
                    configurationKey: "https://wallet.example"
                ).ingress,
                profileIdentifier: nil
            ))
        }
        for id in 204..<208 {
            _ = try accepted(await bridge.enqueue(
                ingress: try makeFixture(
                    id: id,
                    configurationKey: "http://wallet.example"
                ).ingress,
                profileIdentifier: nil
            ))
        }
        guard case .rejected = await bridge.enqueue(
            ingress: try makeFixture(
                id: 208,
                configurationKey: "https://wallet.example"
            ).ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected per-origin rejection") }
    }

    func testSnapshotSequencePreservesFIFOWhenTimestampsTie() async throws {
        for id in 300..<304 {
            _ = try accepted(await bridge.enqueue(
                ingress: try makeFixture(id: id, host: "\(id).example").ingress,
                profileIdentifier: nil
            ))
        }
        guard case .available(let snapshots) = await bridge.list(
            profileIdentifier: nil
        ) else { return XCTFail("Expected snapshots") }
        let fifo = snapshots.values.sorted { left, right in
            if left.createdAt != right.createdAt {
                return left.createdAt < right.createdAt
            }
            return left.sequence < right.sequence
        }
        XCTAssertEqual(fifo.map(\.handle.id), [300, 301, 302, 303])
        XCTAssertEqual(fifo.map(\.sequence), [0, 1, 2, 3])
    }

    func testActiveCapacityIsEightPerProfileAndFourPerOrigin() async throws {
        for id in 0..<ExtensionBridge.maximumRequestsPerHost {
            _ = try accepted(await bridge.enqueue(
                ingress: try makeFixture(id: id, host: "one.example").ingress,
                profileIdentifier: nil
            ))
        }
        guard case .rejected = await bridge.enqueue(
            ingress: try makeFixture(id: 100, host: "one.example").ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected origin capacity rejection") }

        for id in 4..<ExtensionBridge.maximumRequests {
            _ = try accepted(await bridge.enqueue(
                ingress: try makeFixture(id: id, host: "two.example").ingress,
                profileIdentifier: nil
            ))
        }
        guard case .rejected = await bridge.enqueue(
            ingress: try makeFixture(id: 101, host: "three.example").ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected profile capacity rejection") }
    }

    func testSequentialCompletionsKeepReplayWithoutExhaustingActiveCapacity() async throws {
        var completed = [(fixture: Fixture, handle: ExtensionBridge.Handle)]()
        for id in 0..<64 {
            let fixture = try makeFixture(id: id)
            let handle = try accepted(await bridge.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: nil
            )).handle
            let result = await bridge.completeImmediate(
                handle: handle,
                resolution: immediateResolution(for: fixture.request)
            )
            XCTAssertEqual(result, .persisted)
            completed.append((fixture, handle))
        }
        let oldest = try XCTUnwrap(completed.first)
        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        let replay = try accepted(await observer.enqueue(
            ingress: oldest.fixture.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(replay.handle, oldest.handle)
        XCTAssertFalse(replay.approvalRequired)
        let recovered = try responseJSON(await observer.prepareResponseDelivery(
            id: oldest.handle.id,
            configurationKey: oldest.fixture.request.configurationKey,
            requestToken: oldest.handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(recovered["result"] as? String, "0xsigned")

        var activeHandles = Set<ExtensionBridge.Handle>()
        for id in 1000..<(1000 + ExtensionBridge.maximumRequestsPerHost) {
            activeHandles.insert(try accepted(await observer.enqueue(
                ingress: makeFixture(id: id).ingress,
                profileIdentifier: nil
            )).handle)
        }
        guard case .rejected = await observer.enqueue(
            ingress: try makeFixture(id: 2000).ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected unchanged per-origin active limit") }
        for id in 3000..<(3000 + ExtensionBridge.maximumRequests - activeHandles.count) {
            activeHandles.insert(try accepted(await observer.enqueue(
                ingress: makeFixture(id: id, host: "other.example").ingress,
                profileIdentifier: nil
            )).handle)
        }
        guard case .rejected = await observer.enqueue(
            ingress: try makeFixture(id: 4000, host: "third.example").ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected unchanged global active limit") }
        guard case .available(let snapshots) = await observer.list(profileIdentifier: nil)
        else { return XCTFail("Expected bounded snapshots") }
        XCTAssertEqual(snapshots.count, ExtensionBridge.maximumRetainedRequests)
        XCTAssertTrue(activeHandles.isSubset(of: Set(snapshots.keys)))
        XCTAssertNotNil(snapshots[oldest.handle])
        let newest = try XCTUnwrap(completed.last)
        XCTAssertNil(snapshots[newest.handle])
        guard case .found = await observer.load(handle: newest.handle) else {
            return XCTFail("Expected unlisted completion to remain replayable")
        }
    }

    func testResponseAcknowledgmentHidesListingButPreservesReplayAfterRestart() async throws {
        let fixture = try makeFixture(id: 1)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let completion = await bridge.completeImmediate(
            handle: handle,
            resolution: immediateResolution(for: fixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        XCTAssertEqual(
            try firstStoredState("completed")["acknowledged"] as? Bool,
            false
        )
        guard case .available(let initial) = await bridge.list(profileIdentifier: nil)
        else { return XCTFail("Expected unacknowledged listing") }
        XCTAssertNotNil(initial[handle])

        clock.now.addTimeInterval(60)
        let acknowledged = await bridge.acknowledgeResponse(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        )
        XCTAssertEqual(acknowledged, .persisted)
        XCTAssertEqual(
            try firstStoredState("completed")["acknowledged"] as? Bool,
            true
        )
        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .available(let listed) = await observer.list(profileIdentifier: nil)
        else { return XCTFail("Expected acknowledged listing") }
        XCTAssertTrue(listed.isEmpty)
        let replay = try accepted(await observer.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(replay.handle, handle)
        XCTAssertEqual(replay.admissionKind, .replay)
        XCTAssertFalse(replay.approvalRequired)
        let recovered = try responseJSON(await observer.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(recovered["result"] as? String, "0xsigned")
        let failingWriter = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { _, _ in throw Failure.injectedWrite }
        )
        let repeated = await failingWriter.acknowledgeResponse(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        )
        XCTAssertEqual(repeated, .persisted)
        clock.now.addTimeInterval(ExtensionBridge.responseExpiry - 60)
        guard case .missing = await observer.load(handle: handle) else {
            return XCTFail("Acknowledgment must not extend response expiry")
        }
    }

    func testUnacknowledgedResponsesDrainInBoundedOldestFirstBatches() async throws {
        var completed = [ExtensionBridge.Handle]()
        for id in 0..<40 {
            let fixture = try makeFixture(id: id)
            let handle = try accepted(await bridge.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: nil
            )).handle
            let completion = await bridge.completeImmediate(
                handle: handle,
                resolution: immediateResolution(for: fixture.request)
            )
            XCTAssertEqual(completion, .persisted)
            completed.append(handle)
        }
        var active = Set<ExtensionBridge.Handle>()
        for id in 1000..<(1000 + ExtensionBridge.maximumRequestsPerHost) {
            active.insert(try accepted(await bridge.enqueue(
                ingress: makeFixture(id: id).ingress,
                profileIdentifier: nil
            )).handle)
        }
        var acknowledged = [ExtensionBridge.Handle]()
        for _ in 0..<5 {
            let observer = makeBridge(clock: { [clock = clock!] in clock.now })
            guard case .available(let snapshots) = await observer.list(profileIdentifier: nil)
            else { return XCTFail("Expected recoverable response batch") }
            XCTAssertLessThanOrEqual(snapshots.count, ExtensionBridge.maximumRetainedRequests)
            XCTAssertTrue(active.isSubset(of: Set(snapshots.keys)))
            let responses = snapshots.values.filter {
                $0.phase == .responded
            }.sorted { $0.sequence < $1.sequence }
            for response in responses {
                let result = await observer.acknowledgeResponse(
                    handle: response.handle,
                    configurationKey: response.configurationKey
                )
                XCTAssertEqual(result, .persisted)
                acknowledged.append(response.handle)
            }
        }
        XCTAssertEqual(acknowledged, completed)
        guard case .available(let remaining) = await bridge.list(profileIdentifier: nil)
        else { return XCTFail("Expected drained response listing") }
        XCTAssertEqual(Set(remaining.keys), active)
        for handle in completed {
            guard case .found(let snapshot) = await bridge.load(handle: handle) else {
                return XCTFail("Draining responses must retain replay data")
            }
            XCTAssertEqual(snapshot.phase, .responded)
        }
    }

    func testResponseAcknowledgmentRetriesFailedWritesAndVerifiesAmbiguousWrites() async throws {
        let fixture = try makeFixture(id: 1)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let completion = await bridge.completeImmediate(
            handle: handle,
            resolution: immediateResolution(for: fixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        let failingWriter = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { _, _ in throw Failure.injectedWrite }
        )
        let failed = await failingWriter.acknowledgeResponse(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        )
        XCTAssertEqual(failed, .retryablePersistenceFailure)
        guard case .available(let unacknowledged) = await bridge.list(profileIdentifier: nil)
        else { return XCTFail("Expected failed acknowledgment to remain recoverable") }
        XCTAssertNotNil(unacknowledged[handle])

        let ambiguousWriter = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { data, url in
                try ApprovalStoreTestPersistence.write(data, url)
                throw Failure.injectedWrite
            }
        )
        let persisted = await ambiguousWriter.acknowledgeResponse(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        )
        XCTAssertEqual(persisted, .persisted)
        guard case .available(let acknowledged) = await bridge.list(profileIdentifier: nil)
        else { return XCTFail("Expected verified acknowledgment") }
        XCTAssertTrue(acknowledged.isEmpty)
    }

    func testAmbiguousCompletionRequiresExactBytesFromASafeBoundedRead() async throws {
        let callbackRootURL = rootURL!
        enum ReadBack: CaseIterable {
            case exact, stale, altered, missing, symbolicLink, unreadable
            case oversizedFile, oversizedData, emptyData
        }
        for mode in ReadBack.allCases {
            let profileIdentifier = UUID()
            let fixture = try makeFixture(id: 741)
            let handle = try accepted(await bridge.enqueue(
                ingress: try profileFixture(fixture, profileIdentifier: profileIdentifier).ingress,
                profileIdentifier: profileIdentifier
            )).handle
            let targetURL = profileURL(profileIdentifier)
            let recovering = LockedTestValue(false)
            let recoveryReads = LockedTestValue(0)
            let writer = makeBridge(
                clock: { [clock = clock!] in clock.now },
                atomicWrite: { data, url in
                    guard url == targetURL else {
                        return try ApprovalStoreTestPersistence.write(data, url)
                    }
                    recovering.value = true
                    switch mode {
                    case .stale:
                        break
                    case .altered:
                        var profile = try XCTUnwrap(PropertyListSerialization.propertyList(
                            from: data,
                            options: [],
                            format: nil
                        ) as? [String: Any])
                        var records = try XCTUnwrap(profile["records"] as? [[String: Any]])
                        var state = try XCTUnwrap(records[0]["state"] as? [String: Any])
                        var completed = try XCTUnwrap(state["completed"] as? [String: Any])
                        completed["acknowledged"] = true
                        state["completed"] = completed
                        records[0]["state"] = state
                        profile["records"] = records
                        let altered = try PropertyListSerialization.data(
                            fromPropertyList: profile,
                            format: .binary,
                            options: 0
                        )
                        try ApprovalStoreTestPersistence.write(altered, url)
                    case .missing:
                        try FileManager.default.removeItem(at: url)
                    case .symbolicLink:
                        let otherURL = callbackRootURL.appendingPathComponent("readback-target")
                        try data.write(to: otherURL, options: .atomic)
                        try FileManager.default.removeItem(at: url)
                        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: otherURL)
                    case .exact, .unreadable, .oversizedFile, .oversizedData, .emptyData:
                        try ApprovalStoreTestPersistence.write(data, url)
                    }
                    throw Failure.injectedWrite
                },
                readData: { url in
                    if recovering.value, url == targetURL {
                        recoveryReads.withValue { $0 += 1 }
                        switch mode {
                        case .unreadable:
                            throw Failure.injectedWrite
                        case .oversizedData:
                            return Data(repeating: 0, count: ExtensionBridge.maximumRetainedBytes * 2)
                        case .emptyData:
                            return Data()
                        default:
                            break
                        }
                    }
                    return try ExtensionRequestFileStore.defaultReadData(url)
                },
                readFileSize: { url in
                    if recovering.value, url == targetURL, mode == .oversizedFile {
                        return Int.max
                    }
                    return try ExtensionRequestFileStore.defaultReadFileSize(url)
                }
            )
            let result = await writer.completeImmediate(
                handle: handle,
                resolution: immediateResolution(for: fixture.request)
            )
            XCTAssertEqual(
                result,
                mode == .exact ? .persisted : .retryablePersistenceFailure,
                "Read-back mode: \(mode)"
            )
            if [.missing, .symbolicLink, .oversizedFile].contains(mode) {
                XCTAssertEqual(recoveryReads.value, 0, "Unsafe or unbounded data must not be read")
            }
        }
    }

    @MainActor
    func testResponseAcknowledgmentRequiresCompletedExactIdentity() async throws {
        let fixture = try makeTransactionFixture(id: 1)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let pending = await bridge.acknowledgeResponse(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        )
        XCTAssertEqual(pending, .retryablePersistenceFailure)
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        let claimed = await bridge.acknowledgeResponse(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        )
        XCTAssertEqual(claimed, .retryablePersistenceFailure)
        let permit = try await reviewedExecution(claim)
        let prepared = await prepareReviewedBroadcast(permit, in: bridge)
        XCTAssertEqual(prepared, .persisted)
        let broadcasting = await bridge.acknowledgeResponse(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        )
        XCTAssertEqual(broadcasting, .retryablePersistenceFailure)
        let completion = await completeReviewedExecution(permit, in: bridge)
        XCTAssertEqual(completion, .persisted)
        let wrongOrigin = await bridge.acknowledgeResponse(
            handle: handle,
            configurationKey: "https://other.example"
        )
        XCTAssertEqual(wrongOrigin, .ownershipLost)
        let identities = [
            ExtensionBridge.Handle(id: 2, token: handle.token, profileIdentifier: nil),
            ExtensionBridge.Handle(id: handle.id, token: .init(value: UUID()), profileIdentifier: nil),
            ExtensionBridge.Handle(id: handle.id, token: handle.token, profileIdentifier: UUID()),
        ]
        for identity in identities {
            let result = await bridge.acknowledgeResponse(
                handle: identity,
                configurationKey: fixture.request.configurationKey
            )
            XCTAssertEqual(result, .ownershipLost)
        }
        guard case .available(let snapshots) = await bridge.list(profileIdentifier: nil)
        else { return XCTFail("Expected response after rejected acknowledgments") }
        XCTAssertNotNil(snapshots[handle])
    }

    func testResponseIdentityCommandsUseExactIdentityFields() throws {
        let token = UUID().uuidString.lowercased()
        for subject in ["acknowledgeResponse", "showApproval"] {
            let object: [String: Any] = [
                "id": 1,
                "workflowVersion": ExtensionBridge.workflowVersion,
                "subject": subject,
                "configurationKey": "https://wallet.example",
                "requestToken": token,
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            let request = try JSONDecoder().decode(InternalSafariRequest.self, from: data)
            let identity: InternalSafariRequest.ResponseAcknowledgmentIdentity
            switch request.command {
            case .page(.acknowledgeResponse(let value)):
                XCTAssertEqual(subject, "acknowledgeResponse")
                identity = value
            case .page(.showApproval(let value)):
                XCTAssertEqual(subject, "showApproval")
                identity = value
            default:
                return XCTFail("Expected response identity command")
            }
            XCTAssertEqual(request.id, 1)
            XCTAssertEqual(identity.configurationKey, "https://wallet.example")
            XCTAssertEqual(identity.token.rawValue, token)
            for field in ["id", "workflowVersion", "configurationKey", "requestToken"] {
                var missing = object
                missing.removeValue(forKey: field)
                XCTAssertThrowsError(try JSONDecoder().decode(
                    InternalSafariRequest.self,
                    from: JSONSerialization.data(withJSONObject: missing)
                ))
            }
            for field in ["revisions", "executionDeadline", "payload", "reviewToken"] {
                var extra = object
                extra[field] = 1
                XCTAssertThrowsError(try JSONDecoder().decode(
                    InternalSafariRequest.self,
                    from: JSONSerialization.data(withJSONObject: extra)
                ))
            }
        }
    }

    func testRetainedByteCapacityProtectsCompletedDeduplicationWindowThenEvicts() async throws {
        let retained = try await fillCompletedByteCapacity()
        XCTAssertGreaterThan(retained.count, ExtensionBridge.maximumRetainedRequests)
        let oldest = try XCTUnwrap(retained.first)
        clock.now.addTimeInterval(
            ExtensionBridge.requestTTL +
                ExtensionBridge.admissionDeadlineFutureSkew - 1
        )
        let retry = try accepted(await bridge.enqueue(
            ingress: oldest.fixture.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(retry.handle, oldest.handle)
        XCTAssertFalse(retry.approvalRequired)

        let lockURL = operationLockURL(oldest.handle)
        try Data().write(to: lockURL)
        let replacementFixture = try makeFixture(id: 1000, host: "replacement.example")
        guard case .rejected = await bridge.enqueue(
            ingress: replacementFixture.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected protected byte-capacity rejection") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
        let protectedResponse = try responseJSON(await bridge.prepareResponseDelivery(
            id: oldest.handle.id,
            configurationKey: oldest.fixture.request.configurationKey,
            requestToken: oldest.handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual((protectedResponse["error"] as? [String: Any])?["message"] as? String, largeResponseResult)

        clock.now.addTimeInterval(1)
        _ = try accepted(await bridge.enqueue(
            ingress: replacementFixture.ingress,
            profileIdentifier: nil
        ))
        guard case .missing = await bridge.load(handle: oldest.handle) else {
            return XCTFail("Expected eligible oldest completion eviction")
        }
        guard case .found = await bridge.load(handle: retained[1].handle) else {
            return XCTFail("Expected later completed response retention")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
        guard case .expired = await bridge.enqueue(
            ingress: oldest.fixture.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected evicted retry to expire") }
    }

    func testRetainedByteCapacityReservesSpaceForOtherOrigins() async throws {
        let primary = try await fillCompletedByteCapacity(host: "wallet.example")
        XCTAssertGreaterThan(primary.count, ExtensionBridge.maximumRetainedRequestsPerOrigin)
        let secondary = try await fillCompletedByteCapacity(
            startingID: 100,
            host: "other.example"
        )
        XCTAssertGreaterThanOrEqual(secondary.count, 4)
        let retry = try accepted(await bridge.enqueue(
            ingress: primary[0].fixture.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(retry.handle, primary[0].handle)
        XCTAssertFalse(retry.approvalRequired)

        clock.now.addTimeInterval(
            ExtensionBridge.requestTTL + ExtensionBridge.admissionDeadlineFutureSkew
        )
        _ = try accepted(await bridge.enqueue(
            ingress: makeFixture(id: 1001).ingress,
            profileIdentifier: nil
        ))
        guard case .missing = await bridge.load(handle: primary[0].handle) else {
            return XCTFail("Expected oldest same-origin completion eviction")
        }
        for item in secondary {
            guard case .found = await bridge.load(handle: item.handle) else {
                return XCTFail("Expected other origin's replay data to remain")
            }
        }
    }

    func testCompletedChurnRemainsByteBoundedAcrossProtectedWindows() async throws {
        let firstWave = try await fillCompletedByteCapacity()
        clock.now.addTimeInterval(
            ExtensionBridge.requestTTL + ExtensionBridge.admissionDeadlineFutureSkew
        )
        let secondWave = try await fillCompletedByteCapacity(startingID: 100)
        for item in firstWave {
            guard case .missing = await bridge.load(handle: item.handle) else {
                return XCTFail("Expected eligible completion eviction")
            }
            guard case .expired = await bridge.enqueue(
                ingress: item.fixture.ingress,
                profileIdentifier: nil
            ) else { return XCTFail("Expected evicted retry to expire") }
        }
        let profile = try storedProfile()
        let records = try XCTUnwrap(profile["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, secondWave.count)
        let data = try Data(contentsOf: defaultProfileURL)
        XCTAssertLessThanOrEqual(data.count, ExtensionBridge.maximumRetainedBytes + 64 * 1024)
        for item in secondWave {
            guard case .found(let snapshot) = await bridge.load(handle: item.handle) else {
                return XCTFail("Expected recent completion retention")
            }
            XCTAssertEqual(snapshot.phase, .responded)
        }
    }

    @MainActor
    func testCompletedEvictionNeverRemovesActiveRecords() async throws {
        let completed = try await fillCompletedByteCapacity(startingID: 10)
        clock.now.addTimeInterval(
            ExtensionBridge.requestTTL + ExtensionBridge.admissionDeadlineFutureSkew
        )
        let pending = try makeFixture(id: 0, host: "pending.example")
        let pendingHandle = try accepted(await bridge.enqueue(
            ingress: pending.ingress,
            profileIdentifier: nil
        )).handle
        let claimed = try makeFixture(id: 1, host: "claimed.example")
        let claimedHandle = try accepted(await bridge.enqueue(
            ingress: claimed.ingress,
            profileIdentifier: nil
        )).handle
        let claim = try approvalClaim(await bridge.claim(handle: claimedHandle))
        let prepared = try makeTransactionFixture(id: 2, host: "prepared.example")
        let preparedHandle = try accepted(await bridge.enqueue(
            ingress: prepared.ingress,
            profileIdentifier: nil
        )).handle
        let preparedClaim = try approvalClaim(await bridge.claim(handle: preparedHandle))
        let permit = try await reviewedExecution(preparedClaim)
        _ = permit.recoveryResponse
        let preparation = await prepareReviewedBroadcast(permit, in: bridge)
        XCTAssertEqual(preparation, .persisted)
        _ = try accepted(await bridge.enqueue(
            ingress: makeFixture(id: 1000, host: "replacement.example").ingress,
            profileIdentifier: nil
        ))
        guard case .missing = await bridge.load(handle: completed[0].handle) else {
            return XCTFail("Expected eligible completion eviction")
        }
        guard case .found(let pendingSnapshot) = await bridge.load(handle: pendingHandle) else {
            return XCTFail("Expected pending request retention")
        }
        XCTAssertEqual(pendingSnapshot.phase, .queued)
        let repeatedClaim = await bridge.claim(handle: claimedHandle)
        XCTAssertEqual(repeatedClaim, .executing)
        guard case .found(let preparedSnapshot) = await bridge.load(handle: preparedHandle) else {
            return XCTFail("Expected prepared broadcast retention")
        }
        XCTAssertEqual(preparedSnapshot.phase, .approving)
        let release = await bridge.abandon(claim: claim)
        XCTAssertEqual(release, .persisted)
        let completion = await completeReviewedExecution(permit, in: bridge)
        XCTAssertEqual(completion, .persisted)
    }

    @MainActor
    func testAdmissionReservesSpaceForNativeBroadcastAndCompletion() async throws {
        let fixture = try makeTransactionFixture(
            id: 1000,
            host: "signing.example",
            message: "0x" + String(repeating: "ab", count: 120 * 1024)
        )
        let admission = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let runtime = UUID()
        let owner = try XCTUnwrap(ExtensionBridge.NativeDeliveryOwner(
            runtimeInstanceIdentifier: runtime,
            processIdentifier: 42,
            processStartDate: clock.now,
            bundleURL: URL(fileURLWithPath: "/" + String(repeating: "a", count: 4000) + ".app"),
            marketingVersion: String(repeating: "v", count: 128),
            buildVersion: String(repeating: "b", count: 128)
        ))
        let delivered = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            owner: owner
        )
        XCTAssertEqual(delivered, .persisted)
        guard case .claimed(let claim) = await claimDeliveredNativeExecution(in: bridge, handle: admission.handle, approvedAt: clock.now) else { return XCTFail("Expected native claim") }
        let permit = try await reviewedExecution(claim)
        _ = try await fillCompletedByteCapacity()
        let prepared = await prepareReviewedBroadcast(permit, in: bridge)
        XCTAssertEqual(prepared, .persisted)
        guard case .found(let checkpoint) = await bridge.load(handle: admission.handle) else {
            return XCTFail("Expected prepared native broadcast")
        }
        XCTAssertNotNil(checkpoint.nativeApproval)
        XCTAssertEqual(checkpoint.nativeDeliveryReceipt?.owner, owner)
        XCTAssertNil(checkpoint.nativeExecutionContext)
        let completion = await completeReviewedExecution(permit, in: bridge)
        XCTAssertEqual(completion, .persisted)
        XCTAssertLessThanOrEqual(
            try Data(contentsOf: defaultProfileURL).count,
            ExtensionBridge.maximumRetainedBytes + 64 * 1024
        )
    }

    func testAllActiveCapacityRejectsWithoutEviction() async throws {
        var handles = [ExtensionBridge.Handle]()
        for id in 0..<ExtensionBridge.maximumRequests {
            handles.append(try accepted(await bridge.enqueue(
                ingress: try makeFixture(id: id, host: "\(id).example").ingress,
                profileIdentifier: nil
            )).handle)
        }

        guard case .rejected = await bridge.enqueue(
            ingress: try makeFixture(id: 1000, host: "replacement.example").ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected all-active rejection") }
        guard case .available(let snapshots) = await bridge.list(
            profileIdentifier: nil
        ) else { return XCTFail("Expected active snapshots") }
        XCTAssertEqual(Set(snapshots.keys), Set(handles))
    }

    func testPendingAndCompletedRecordsExpireAtTheirSeparateTTLs() async throws {
        let pending = try makeFixture(id: 20)
        let pendingHandle = try accepted(await bridge.enqueue(
            ingress: pending.ingress,
            profileIdentifier: nil
        )).handle
        clock.now.addTimeInterval(ExtensionBridge.requestTTL)
        guard case .found(let expiredPending) = await bridge.load(handle: pendingHandle) else {
            return XCTFail("Expected retained pending expiry")
        }
        XCTAssertEqual(expiredPending.phase, .responded)
        let rejection = try responseJSON(await bridge.prepareResponseDelivery(
            id: pendingHandle.id,
            configurationKey: pending.request.configurationKey,
            requestToken: pendingHandle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual((rejection["error"] as? [String: Any])?["code"] as? Int, 4001)
        let retry = try accepted(await bridge.enqueue(
            ingress: pending.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(retry.handle, pendingHandle)
        XCTAssertFalse(retry.approvalRequired)
        clock.now.addTimeInterval(ExtensionBridge.responseExpiry)
        guard case .missing = await bridge.load(handle: pendingHandle) else {
            return XCTFail("Expected expired rejection response")
        }

        let completed = try makeFixture(id: 21)
        let completedHandle = try accepted(await bridge.enqueue(
            ingress: completed.ingress,
            profileIdentifier: nil
        )).handle
        let completion = await bridge.completeImmediate(
            handle: completedHandle,
            resolution: immediateResolution(for: completed.request)
        )
        XCTAssertEqual(completion, .persisted)
        clock.now.addTimeInterval(ExtensionBridge.responseExpiry)
        guard case .missing = await bridge.load(handle: completedHandle) else {
            return XCTFail("Expected expired response")
        }
    }

    func testPendingCompletionAtDeadlineRetainsUserRejection() async throws {
        let fixture = try makeFixture(id: 94)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        clock.now.addTimeInterval(ExtensionBridge.requestTTL)

        let completion = await bridge.completeImmediate(
            handle: handle,
            resolution: immediateResolution(for: fixture.request)
        )
        XCTAssertEqual(completion, .ownershipLost)
        let rejection = try responseJSON(await bridge.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual((rejection["error"] as? [String: Any])?["code"] as? Int, 4001)
        XCTAssertNil(rejection["result"])
    }

    func testProfilesAreIndependent() async throws {
        let fixture = try makeFixture(id: 30)
        let firstProfile = UUID()
        let secondProfile = UUID()
        let first = try accepted(await bridge.enqueue(
            ingress: try profileFixture(fixture, profileIdentifier: firstProfile).ingress,
            profileIdentifier: firstProfile
        )).handle
        let second = try accepted(await bridge.enqueue(
            ingress: try profileFixture(fixture, profileIdentifier: secondProfile).ingress,
            profileIdentifier: secondProfile
        )).handle
        XCTAssertNotEqual(first, second)
        let completion = await bridge.completeImmediate(
            handle: first,
            resolution: immediateResolution(for: fixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        guard case .response = await bridge.prepareResponseDelivery(
            id: first.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: first.requestToken,
            profileIdentifier: firstProfile
        ) else { return XCTFail("Expected first profile response") }
        guard case .pending = await bridge.prepareResponseDelivery(
            id: second.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: second.requestToken,
            profileIdentifier: secondProfile
        ) else { return XCTFail("Expected second profile pending") }
    }

    func testMaintenanceRetainsAuthorityEpochAfterRequestsExpire() async throws {
        let inactiveProfile = UUID()
        let fixture = try makeFixture(id: 31)
        let handle = try accepted(await bridge.enqueue(
            ingress: try profileFixture(fixture, profileIdentifier: inactiveProfile).ingress,
            profileIdentifier: inactiveProfile
        )).handle
        let completion = await bridge.completeImmediate(
            handle: handle,
            resolution: immediateResolution(for: fixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        let inactiveURL = profileURL(inactiveProfile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inactiveURL.path))

        clock.now.addTimeInterval(ExtensionBridge.responseExpiry)
        await bridge.performMaintenance()
        XCTAssertTrue(FileManager.default.fileExists(atPath: inactiveURL.path))
    }

    func testQueueAccessDoesNotSweepExpiredInactiveProfile() async throws {
        let inactiveProfile = UUID()
        let fixture = try makeFixture(id: 35)
        let handle = try accepted(await bridge.enqueue(
            ingress: try profileFixture(fixture, profileIdentifier: inactiveProfile).ingress,
            profileIdentifier: inactiveProfile
        )).handle
        let completion = await bridge.completeImmediate(
            handle: handle,
            resolution: immediateResolution(for: fixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        let inactiveURL = profileURL(inactiveProfile)
        clock.now.addTimeInterval(ExtensionBridge.responseExpiry)
        let pollingFixture = try makeFixture(id: 36)
        let pollingHandle = try accepted(await bridge.enqueue(
            ingress: pollingFixture.ingress,
            profileIdentifier: nil
        )).handle
        XCTAssertTrue(FileManager.default.fileExists(atPath: inactiveURL.path))

        for _ in 0..<3 {
            guard case .found = await bridge.load(handle: pollingHandle) else {
                return XCTFail("Expected polled request")
            }
            guard case .pending = await bridge.prepareResponseDelivery(
                id: pollingHandle.id,
                configurationKey: pollingFixture.request.configurationKey,
                requestToken: pollingHandle.requestToken,
                profileIdentifier: nil
            ) else { return XCTFail("Expected pending polled response") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: inactiveURL.path))

        guard case .available = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected current profile listing")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: inactiveURL.path))
        await bridge.performMaintenance()
        XCTAssertTrue(FileManager.default.fileExists(atPath: inactiveURL.path))
    }

    func testMaintenanceRetainsAlreadyEmptyAuthorityProfile() async throws {
        let inactiveProfile = UUID()
        let inactiveURL = profileURL(inactiveProfile)
        _ = try accepted(await bridge.enqueue(
            ingress: try profileFixture(makeFixture(id: 34), profileIdentifier: inactiveProfile).ingress,
            profileIdentifier: inactiveProfile
        ))
        var profile = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: inactiveURL),
                options: [],
                format: nil
            ) as? [String: Any]
        )
        profile["records"] = [[String: Any]]()
        try PropertyListSerialization.data(
            fromPropertyList: profile,
            format: .binary,
            options: 0
        ).write(to: inactiveURL, options: .atomic)

        await bridge.performMaintenance()
        XCTAssertTrue(FileManager.default.fileExists(atPath: inactiveURL.path))
    }

    func testUnavailableInactiveProfileDoesNotBlockCurrentProfile() async throws {
        guard case .available = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected initialized store")
        }
        let inactiveProfile = UUID()
        let inactiveURL = profileURL(inactiveProfile)
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: inactiveURL, options: .atomic)
        let orphanHandle = ExtensionBridge.Handle(
            id: 32,
            token: .init(value: UUID()),
            profileIdentifier: inactiveProfile
        )
        let orphanLockURL = operationLockURL(orphanHandle)
        try Data().write(to: orphanLockURL)

        guard case .available = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected current profile despite corrupt inactive profile")
        }
        await bridge.performMaintenance()
        XCTAssertEqual(try Data(contentsOf: inactiveURL), corrupt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanLockURL.path))
    }

    func testMaintenanceCleansAllEligibleProfilesAndPreservesHeldClaims() async throws {
        var heldClaims = [ExtensionBridge.ApprovalClaim]()
        defer { heldClaims.forEach { $0.releaseUnapproved() } }
        var heldURLs = [URL]()
        var expiredURLs = [URL]()
        for index in 0..<6 {
            let identifier = UUID()
            let fixture = try makeFixture(id: 200 + index)
            let handle = try accepted(await bridge.enqueue(
                ingress: try profileFixture(fixture, profileIdentifier: identifier).ingress, profileIdentifier: identifier
            )).handle
            if index < 2 {
                heldClaims.append(try approvalClaim(await bridge.claim(handle: handle)))
                heldURLs.append(profileURL(identifier))
            } else {
                let completed = await bridge.completeImmediate(handle: handle, resolution: immediateResolution(for: fixture.request))
                XCTAssertEqual(completed, .persisted)
                expiredURLs.append(profileURL(identifier))
            }
        }
        clock.now.addTimeInterval(ExtensionBridge.responseExpiry)
        await bridge.performMaintenance()
        XCTAssertTrue(heldURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(expiredURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        for url in expiredURLs {
            let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: Any])
            XCTAssertEqual((profile["records"] as? [Any])?.count, 0)
            XCTAssertNotNil(profile["authorityEpoch"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultProfileURL.deletingLastPathComponent().appendingPathComponent("sweep.cursor").path))
    }

    func testMaintenanceLeavesUnrelatedOrphanOperationLock() async throws {
        guard case .available = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected initialized store")
        }
        let handle = ExtensionBridge.Handle(
            id: 33,
            token: .init(value: UUID()),
            profileIdentifier: UUID()
        )
        let lockURL = operationLockURL(handle)
        try Data().write(to: lockURL)

        await bridge.performMaintenance()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testMaintenanceDoesNotFollowProfileSymlinks() async throws {
        guard case .available = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected initialized store")
        }
        let inactiveURL = profileURL(UUID())
        let targetURL = rootURL.appendingPathComponent("profile-target")
        let targetData = Data("outside".utf8)
        try targetData.write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: inactiveURL,
            withDestinationURL: targetURL
        )

        await bridge.performMaintenance()
        XCTAssertEqual(try Data(contentsOf: targetURL), targetData)
        XCTAssertNotNil(
            try? FileManager.default.destinationOfSymbolicLink(atPath: inactiveURL.path)
        )
    }

    func testDroppedClaimReturnsToPendingAndCanBeClaimedAgain() async throws {
        let fixture = try makeFixture(id: 40)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        var claim: ExtensionBridge.ApprovalClaim? = try approvalClaim(
            await bridge.claim(handle: handle)
        )
        guard case .found(let claimed) = await bridge.load(handle: handle) else {
            return XCTFail("Expected claimed snapshot")
        }
        XCTAssertEqual(claimed.phase, .approving)
        claim?.releaseUnapproved()
        claim = nil

        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .found(let recovered) = await observer.load(handle: handle) else {
            return XCTFail("Expected recovered snapshot")
        }
        XCTAssertEqual(recovered.phase, .queued)
        _ = try approvalClaim(await observer.claim(handle: handle))
    }

    func testDroppedClaimAfterDeadlineBecomesRetainedRejection() async throws {
        let fixture = try makeFixture(id: 93)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        var claim: ExtensionBridge.ApprovalClaim? = try approvalClaim(
            await bridge.claim(handle: handle)
        )
        clock.now.addTimeInterval(ExtensionBridge.requestTTL)
        claim?.releaseUnapproved()
        claim = nil

        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .found(let recovered) = await observer.load(handle: handle) else {
            return XCTFail("Expected recovered rejection")
        }
        XCTAssertEqual(recovered.phase, .responded)
        let response = try responseJSON(await observer.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, 4001)
    }

    func testAbandonRestoresClaimedAndAdoptedRequestsAndRetainsExpiredRejections() async throws {
        for (operationIndex, adopted) in [false, true].enumerated() {
            for (expiryIndex, expires) in [false, true].enumerated() {
                let fixture = try makeFixture(id: 950 + operationIndex * 2 + expiryIndex)
                let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
                let claim = try approvalClaim(await bridge.claim(handle: handle))
                if adopted { XCTAssertTrue(claim.adoptForExecution()) }
                if expires { clock.now.addTimeInterval(ExtensionBridge.requestTTL) }
                let result = await bridge.abandon(claim: claim)
                XCTAssertEqual(result, .persisted)
                XCTAssertFalse(FileManager.default.fileExists(atPath: operationLockURL(handle).path))
                guard case .found(let abandoned) = await bridge.load(handle: handle) else {
                    return XCTFail("Expected retained request")
                }
                XCTAssertEqual(abandoned.phase, expires ? .responded : .queued)
                if expires {
                    let response = try responseJSON(await bridge.prepareResponseDelivery(
                        id: handle.id, configurationKey: fixture.request.configurationKey,
                        requestToken: handle.requestToken, profileIdentifier: nil
                    ))
                    XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, 4001)
                } else {
                    let reclaimed = try approvalClaim(await bridge.claim(handle: handle))
                    let secondAbandon = await bridge.abandon(claim: reclaimed)
                    XCTAssertEqual(secondAbandon, .persisted)
                }
            }
        }
    }

    func testFailedAbandonRelinquishesOwnershipAndRecoversWithoutReusingClaim() async throws {
        for (nativeIndex, native) in [false, true].enumerated() {
            for (operationIndex, adopted) in [false, true].enumerated() {
                for (failureIndex, persistsBeforeFailure) in [false, true].enumerated() {
                    let fixture = try makeFixture(id: 960 + nativeIndex * 4 + operationIndex * 2 + failureIndex, name: "requestAccounts")
                    let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
                    let claim: ExtensionBridge.ApprovalClaim
                    if native {
                        let delivered = try await recordNativeDelivery(handle: handle)
                        XCTAssertEqual(delivered, .persisted)
                        guard case .claimed(let value) = await claimDeliveredNativeExecution(
                            in: bridge, handle: handle, approvedAt: clock.now
                        ) else { return XCTFail("Expected native claim") }
                        claim = value
                    } else {
                        claim = try approvalClaim(await bridge.claim(handle: handle))
                    }
                    if adopted { XCTAssertTrue(claim.adoptForExecution()) }
                    let writes = LockedTestValue(0)
                    let failingWriter = makeBridge(clock: { [clock = clock!] in clock.now }, atomicWrite: { data, url in
                        writes.withValue { $0 += 1 }
                        if persistsBeforeFailure { try ApprovalStoreTestPersistence.write(data, url) }
                        throw Failure.injectedWrite
                    })
                    let result = await failingWriter.abandon(claim: claim)
                    XCTAssertEqual(result, .retryablePersistenceFailure)
                    let competingLock = CrossProcessFileLock(fileURL: operationLockURL(handle))
                    XCTAssertTrue(try competingLock.tryAcquireExisting())
                    competingLock.release()
                    let repeated = await failingWriter.abandon(claim: claim)
                    XCTAssertEqual(repeated, .ownershipLost)
                    XCTAssertEqual(writes.value, 1)
                    XCTAssertFalse(claim.adoptForExecution())
                    let observer = makeBridge(clock: { [clock = clock!] in clock.now })
                    guard case .found(let recovered) = await observer.load(handle: handle) else {
                        return XCTFail("A fresh observer must recover the persisted phase")
                    }
                    XCTAssertEqual(recovered.phase, native ? .responded : .queued)
                    if native {
                        let response = try responseJSON(await observer.prepareResponseDelivery(
                            id: handle.id, configurationKey: fixture.request.configurationKey,
                            requestToken: handle.requestToken, profileIdentifier: nil
                        ))
                        XCTAssertEqual(NSDictionary(dictionary: response), NSDictionary(dictionary: ResponseToExtension(
                            for: fixture.request, payload: .error(.approvalInterrupted)
                        ).json))
                    } else {
                        let fresh = try approvalClaim(await observer.claim(handle: handle))
                        XCTAssertTrue(fresh.adoptForExecution())
                        let abandoned = await observer.abandon(claim: fresh)
                        XCTAssertEqual(abandoned, .persisted)
                        let rejected = await observer.reject(handle: handle)
                        XCTAssertEqual(rejected, .persisted)
                    }
                }
            }
        }
    }

    func testClaimCanBeAdoptedOnlyOnceAcrossCopies() async throws {
        let fixture = try makeFixture(id: 41)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        let copy = claim
        XCTAssertTrue(claim.adoptForExecution())
        XCTAssertFalse(copy.adoptForExecution())
        let abandoned = await bridge.abandon(claim: claim)
        XCTAssertEqual(abandoned, .persisted)
    }

    @MainActor
    func testAuthorizationRequiresAdoptionWithoutConsumingValidConsent() async throws {
        let fixture = try makeTransactionFixture(id: 60_049)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        let approval = try reviewedApproval(claim)
        let unadopted = await bridge.authorize(claim: claim, approval: approval)
        XCTAssertEqual(unadopted, .ownershipLost)
        XCTAssertTrue(claim.adoptForExecution())
        guard case .authorized(let permit) = await bridge.authorize(claim: claim, approval: approval) else {
            return XCTFail("Invalid candidates must leave the valid consent usable")
        }
        let abandoned = await bridge.abandon(permit: permit)
        XCTAssertEqual(abandoned, .persisted)
    }

    @MainActor
    func testAuthorizeRejectsDifferentRequestWithoutConsumingEitherConsentOrClaim() async throws {
        let first = try makeTransactionFixture(id: 60_050)
        let second = try makeTransactionFixture(id: 60_051)
        let firstHandle = try accepted(await bridge.enqueue(ingress: first.ingress, profileIdentifier: nil)).handle
        let secondHandle = try accepted(await bridge.enqueue(ingress: second.ingress, profileIdentifier: nil)).handle
        let firstClaim = try approvalClaim(await bridge.claim(handle: firstHandle))
        let secondClaim = try approvalClaim(await bridge.claim(handle: secondHandle))
        XCTAssertTrue(firstClaim.adoptForExecution())
        XCTAssertTrue(secondClaim.adoptForExecution())
        let firstApproval = try reviewedApproval(firstClaim)
        let secondApproval = try reviewedApproval(secondClaim)
        let mismatched = await bridge.authorize(claim: firstClaim, approval: secondApproval)
        XCTAssertEqual(mismatched, .ownershipLost)
        guard case .authorized(let firstPermit) = await bridge.authorize(claim: firstClaim, approval: firstApproval),
              case .authorized(let secondPermit) = await bridge.authorize(claim: secondClaim, approval: secondApproval) else {
            return XCTFail("A mismatched candidate must leave both rightful authorizations usable")
        }
        let firstAbandoned = await bridge.abandon(permit: firstPermit)
        let secondAbandoned = await bridge.abandon(permit: secondPermit)
        XCTAssertEqual(firstAbandoned, .persisted)
        XCTAssertEqual(secondAbandoned, .persisted)
    }

    @MainActor
    func testUnapprovedClaimsCannotCompleteSigningOrGrantResults() async throws {
        for (index, signing) in [false, true].enumerated() {
            let fixture = signing
                ? try makeTransactionFixture(id: 76_000 + index, host: "signing-boundary.example")
                : try makeFixture(id: 76_000 + index, name: "requestAccounts", host: "grant-boundary.example")
            let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            XCTAssertTrue(claim.adoptForExecution())
            for resolution in [ImmediateResolution.existingEthereumAccounts, .ethereumRecoveredAddress("0xsigned"), .ethereumChain("0x1")] {
                let result = await bridge.complete(claim: claim, resolution: resolution)
                XCTAssertEqual(result, .ownershipLost)
            }
            let authority = try await removalSnapshot(host: signing ? "signing-boundary.example" : "grant-boundary.example")
            if !signing { XCTAssertNil(authority.ethereumAccount) }
            let abandoned = await bridge.abandon(claim: claim)
            XCTAssertEqual(abandoned, .persisted)
        }
    }

    @MainActor
    func testAuthorizationRequiresMatchingProfileAndNativeReceipt() async throws {
        let fixture = try makeTransactionFixture(id: 76_010)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let profile = UUID()
        let foreign = try profileFixture(fixture, profileIdentifier: profile)
        let foreignHandle = try accepted(await bridge.enqueue(ingress: foreign.ingress, profileIdentifier: profile)).handle
        let foreignClaim = try approvalClaim(await bridge.claim(handle: foreignHandle))
        XCTAssertTrue(foreignClaim.adoptForExecution())
        let foreignApproval = try reviewedApproval(foreignClaim)
        let ordinaryClaim = try approvalClaim(await bridge.claim(handle: handle))
        XCTAssertTrue(ordinaryClaim.adoptForExecution())
        let wrongProfile = await bridge.authorize(claim: ordinaryClaim, approval: foreignApproval)
        XCTAssertEqual(wrongProfile, .ownershipLost)
        let ordinaryAbandoned = await bridge.abandon(claim: ordinaryClaim)
        XCTAssertEqual(ordinaryAbandoned, .persisted)
        let delivered = try await recordNativeDelivery(handle: handle)
        XCTAssertEqual(delivered, .persisted)
        guard case .claimed(let claim) = await claimDeliveredNativeExecution(in: bridge, handle: handle, approvedAt: clock.now) else { return XCTFail("Expected native claim") }
        XCTAssertTrue(claim.adoptForExecution())
        let request = claim.request
        let account = try XCTUnwrap(request.authorizedAccount)
        let catalog = WalletReviewCatalog(identity: .init(generation: nil, catalogData: Data()), orderedAccounts: [account.specificAccount])
        guard case .approval(let intent) = DappRequestProcessor().prepare(claim.binding, catalog: catalog),
              case .approveTransaction(let transaction) = intent.action,
              case .found(let snapshot) = await bridge.load(handle: handle) else { return XCTFail("Expected transaction review") }
        let execution = try XCTUnwrap(DappApprovalDecision.TransactionExecution(Self.preparedTransactionForStorage(transaction), reviewedNetwork: transaction.resolvedNetwork, approvedAccount: account))
        let wrongReceipt = ExtensionBridge.NativeDeliveryReceipt(nativeDeliveryNonce: snapshot.nativeDeliveryNonce, owner: storedRequestNativeOwner())
        let wrongApproval = try resolvedApprovalForTesting(snapshot: snapshot, action: intent.action, decision: .transaction(execution), approvedAt: clock.now, nativeReceipt: wrongReceipt)
        let rejected = await bridge.authorize(claim: claim, approval: wrongApproval)
        XCTAssertEqual(rejected, .ownershipLost)
        let validApproval = try reviewedApproval(claim)
        guard case .authorized(let permit) = await bridge.authorize(claim: claim, approval: validApproval),
              case .authorized(let foreignPermit) = await bridge.authorize(claim: foreignClaim, approval: foreignApproval) else {
            return XCTFail("The rightful receipt and profile must remain authorizable")
        }
        let abandoned = await bridge.abandon(permit: permit)
        let foreignAbandoned = await bridge.abandon(permit: foreignPermit)
        XCTAssertEqual(abandoned, .persisted)
        XCTAssertEqual(foreignAbandoned, .persisted)
    }

    @MainActor
    func testRevokedChainAdditionDoesNotInsertNetwork() async throws {
        let additions = LockedTestValue(0)
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { [clock = clock!] in clock.now }, atomicWrite: ApprovalStoreTestPersistence.write,
            completeChainAddition: { _ in additions.withValue { $0 += 1 }; return true }
        ))
        let permit = try authorizeChainAddition(in: store)
        guard case .snapshot(let authority) = store.configurationSnapshot(
            configurationKey: permit.request.configurationKey, profileIdentifier: nil
        ), case .revoked = store.revoke(
            configurationKey: permit.request.configurationKey, provider: .ethereum,
            attempt: attempt(for: 77_040), expected: authority.version, profileIdentifier: nil
        ), case .completed(let completion) = await DappRequestProcessor().execute(permit: permit, signer: nil) else {
            return XCTFail("Expected revocation between authorization and execution")
        }
        XCTAssertEqual(store.complete(permit: permit, result: completion), .persisted)
        XCTAssertEqual(additions.value, 0)
        let delivery = try await deliveredAuthority(permit.handle)
        XCTAssertEqual((delivery.response["error"] as? [String: Any])?["code"] as? Int, 4100)
        XCTAssertEqual((delivery.state["ethereum"] as? [String: String])?["chainId"], "0x1")
    }

    @MainActor
    func testChainAdditionInsertsOnceUnderAuthorityLock() async throws {
        let additions = LockedTestValue(0)
        let competingLock = CrossProcessFileLock(fileURL: rootURL.appendingPathComponent("bridge-v9.lock"))
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { [clock = clock!] in clock.now }, atomicWrite: ApprovalStoreTestPersistence.write,
            completeChainAddition: { permit in
                XCTAssertTrue(permit.isExecuting)
                XCTAssertEqual(try? competingLock.tryAcquireExisting(), false)
                additions.withValue { $0 += 1 }
                return true
            }
        ))
        let permit = try authorizeChainAddition(in: store)
        guard case .completed(let completion) = await DappRequestProcessor().execute(permit: permit, signer: nil) else {
            return XCTFail("Expected deferred chain addition")
        }
        XCTAssertEqual(additions.value, 0)
        XCTAssertEqual(store.complete(permit: permit, result: completion), .persisted)
        XCTAssertEqual(store.complete(permit: permit, result: completion), .persisted)
        XCTAssertEqual(additions.value, 1)
        XCTAssertTrue(try competingLock.tryAcquireExisting())
        competingLock.release()
        let delivery = try await deliveredAuthority(permit.handle)
        XCTAssertTrue(delivery.response["result"] is NSNull)
        XCTAssertEqual((delivery.state["ethereum"] as? [String: String])?["chainId"], "0x7ffffffffffffffe")
    }

    @MainActor
    func testChainAdditionIsNotRepeatedAfterTerminalWriteFailure() async throws {
        for writesBeforeFailing in [false, true] {
            let directory = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let failWrite = LockedTestValue(false)
            let failSynchronization = LockedTestValue(true)
            let additions = LockedTestValue(0)
            let publications = LockedTestValue(0)
            let store = ExtensionRequestFileStore(rootURL: directory, directoryBoundary: directory, dependencies: .init(
                clock: { [clock = clock!] in clock.now },
                atomicWrite: { data, url in
                    guard failWrite.value else {
                        return try ApprovalStoreTestPersistence.write(data, url)
                    }
                    publications.withValue { $0 += 1 }
                    if writesBeforeFailing { try ApprovalStoreTestPersistence.write(data, url) }
                    throw Failure.injectedWrite
                },
                synchronizePublishedFile: { url in
                    if failSynchronization.value { throw Failure.injectedWrite }
                    try ApprovalStoreTestPersistence.synchronize(url)
                },
                completeChainAddition: { permit in
                    XCTAssertTrue(permit.isExecuting)
                    additions.withValue { $0 += 1 }
                    return true
                }
            ))
            let permit = try authorizeChainAddition(in: store)
            guard case .completed(let completion) = await DappRequestProcessor().execute(permit: permit, signer: nil) else {
                return XCTFail("Expected approved chain addition")
            }
            failWrite.value = true
            XCTAssertEqual(store.complete(permit: permit, result: completion), .retryablePersistenceFailure)
            XCTAssertEqual(store.complete(permit: permit, result: completion),
                writesBeforeFailing ? .retryablePersistenceFailure : .ownershipLost)
            failSynchronization.value = false
            XCTAssertEqual(store.complete(permit: permit, result: completion),
                writesBeforeFailing ? .persisted : .ownershipLost)
            XCTAssertEqual(additions.value, 1)
            XCTAssertEqual(publications.value, 1)
        }
    }

    @MainActor
    func testUnrelatedCompletionDoesNotConsumeRightfulExecution() async throws {
        let firstFixture = try makeTransactionFixture(id: 76_050)
        let firstHandle = try accepted(await bridge.enqueue(ingress: firstFixture.ingress, profileIdentifier: nil)).handle
        let secondFixture = try makeTransactionFixture(id: 76_051)
        let secondHandle = try accepted(await bridge.enqueue(ingress: secondFixture.ingress, profileIdentifier: nil)).handle
        let first = try await reviewedExecution(approvalClaim(await bridge.claim(handle: firstHandle)))
        let second = try await reviewedExecution(approvalClaim(await bridge.claim(handle: secondHandle)))
        let mismatch = await completeReviewedExecution(first, result: second.completion, in: bridge)
        XCTAssertEqual(mismatch, .ownershipLost)
        XCTAssertTrue(first.permit.isExecuting)
        let competingLock = CrossProcessFileLock(fileURL: operationLockURL(firstHandle))
        XCTAssertFalse(try competingLock.tryAcquireExisting())
        let firstResult = await completeReviewedExecution(first, in: bridge)
        let secondResult = await completeReviewedExecution(second, in: bridge)
        XCTAssertEqual(firstResult, .persisted)
        XCTAssertEqual(secondResult, .persisted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: operationLockURL(firstHandle).path))
    }

    func testClosedUnapprovedCompletionObservesWithoutMaintenanceOrRepublication() async throws {
        for (index, writesBeforeFailing) in [false, true].enumerated() {
            let profileIdentifier = UUID()
            let fixture = try profileFixture(makeFixture(id: 76_060 + index * 3), profileIdentifier: profileIdentifier)
            let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: profileIdentifier)).handle
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            XCTAssertTrue(claim.adoptForExecution())
            let expiring = try profileFixture(makeFixture(id: 76_061 + index * 3,
                admissionDeadline: clock.now.addingTimeInterval(1)), profileIdentifier: profileIdentifier)
            _ = try accepted(await bridge.enqueue(ingress: expiring.ingress, profileIdentifier: profileIdentifier))
            let abandoned = try profileFixture(makeFixture(id: 76_062 + index * 3), profileIdentifier: profileIdentifier)
            let abandonedHandle = try accepted(await bridge.enqueue(ingress: abandoned.ingress, profileIdentifier: profileIdentifier)).handle
            let abandonedClaim = try approvalClaim(await bridge.claim(handle: abandonedHandle))
            let publications = LockedTestValue(0)
            let synchronizations = LockedTestValue(0)
            let writer = makeBridge(clock: { [clock = clock!] in clock.now }, atomicWrite: { data, url in
                publications.withValue { $0 += 1 }
                if writesBeforeFailing { try ApprovalStoreTestPersistence.write(data, url) }
                throw Failure.injectedWrite
            }, synchronizePublishedFile: { url in
                synchronizations.withValue { $0 += 1 }
                try ApprovalStoreTestPersistence.synchronize(url)
            })
            let first = await writer.complete(claim: claim, resolution: immediateResolution(for: fixture.request))
            XCTAssertEqual(first, .retryablePersistenceFailure)
            abandonedClaim.releaseUnapproved()
            clock.now.addTimeInterval(2)
            let stored = try Data(contentsOf: profileURL(profileIdentifier))
            let repeated = await writer.complete(claim: claim, resolution: immediateResolution(for: fixture.request))
            XCTAssertEqual(repeated, writesBeforeFailing ? .persisted : .ownershipLost)
            XCTAssertEqual(publications.value, 1)
            XCTAssertEqual(synchronizations.value, writesBeforeFailing ? 1 : 0)
            XCTAssertEqual(try Data(contentsOf: profileURL(profileIdentifier)), stored)
        }
    }

    @MainActor
    func testFailedChainAdditionDoesNotChangeSelectedNetwork() async throws {
        let additions = LockedTestValue(0)
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { [clock = clock!] in clock.now }, atomicWrite: ApprovalStoreTestPersistence.write,
            completeChainAddition: { _ in additions.withValue { $0 += 1 }; return false }
        ))
        let permit = try authorizeChainAddition(in: store)
        guard case .completed(let completion) = await DappRequestProcessor().execute(permit: permit, signer: nil) else {
            return XCTFail("Expected deferred chain addition")
        }
        XCTAssertEqual(store.complete(permit: permit, result: completion), .persisted)
        XCTAssertEqual(additions.value, 1)
        let delivery = try await deliveredAuthority(permit.handle)
        XCTAssertNotNil(delivery.response["error"])
        XCTAssertEqual((delivery.state["ethereum"] as? [String: String])?["chainId"], "0x1")
    }

    @MainActor
    func testChainAdditionFailureCompletionDoesNotInsertNetwork() async throws {
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { [clock = clock!] in clock.now }, atomicWrite: ApprovalStoreTestPersistence.write,
            completeChainAddition: { _ in XCTFail("Failed approvals must not insert networks"); return true }
        ))
        let permit = try authorizeChainAddition(in: store)
        XCTAssertTrue(permit.consumeExecution())
        let completion = try XCTUnwrap(ApprovedCompletion.failure(.internalError, permit: permit))
        XCTAssertEqual(store.complete(permit: permit, result: completion), .persisted)
        let delivery = try await deliveredAuthority(permit.handle)
        XCTAssertNotNil(delivery.response["error"])
        XCTAssertEqual((delivery.state["ethereum"] as? [String: String])?["chainId"], "0x1")
    }

    @MainActor
    private func authorizeChainAddition(
        in store: ExtensionRequestFileStore
    ) throws -> ExtensionBridge.ApprovedExecutionPermit {
        let template = try makeFixture(id: 76_040, name: "addEthereumChain")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: template.ingress.canonicalData) as? [String: Any])
        guard case .snapshot(let authority) = store.configurationSnapshot(
            configurationKey: template.request.configurationKey, profileIdentifier: nil
        ) else { throw Failure.expectedValue }
        raw["authority"] = authority.version.json
        raw["body"] = ["address": "", "chainId": "0x1", "object": [
            "chainId": "0x7ffffffffffffffe", "chainName": "Test Network",
            "rpcUrls": ["https://rpc.example"], "blockExplorerUrls": [],
            "nativeCurrency": ["decimals": 18, "name": "Test Ether", "symbol": "TETH"],
        ]]
        let fixture = try authorityFixture(raw)
        let handle = try accepted(store.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let claim = try approvalClaim(store.claim(handle: handle))
        guard case .found(let snapshot) = store.load(handle: handle) else { throw Failure.expectedValue }
        let consent = try Self.reviewedConsent(snapshot, approvedAt: clock.now)
        let approval = try consent.resolve(context: approvalResolutionContextForTesting(
            action: consent.intent.action, decision: consent.decision, accounts: []
        )).get()
        guard claim.adoptForExecution(),
              case .authorized(let permit) = store.authorize(claim: claim, approval: approval) else {
            throw Failure.expectedValue
        }
        return permit
    }

    @MainActor
    func testSigningAuthorityGateHoldsTheCommonStoreLockAndPropagatesOperationFailure() async throws {
        let fixture = try makeTransactionFixture(id: 76_110, host: "signing-gate.example")
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        let execution = try await reviewedExecution(claim)
        defer { execution.releaseLease() }
        let contender = CrossProcessFileLock(fileURL: rootURL.appendingPathComponent("bridge-v9.lock"))
        let result = try execution.permit.withCurrentAuthority {
            XCTAssertFalse(try contender.tryAcquireExisting())
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertThrowsError(try execution.permit.withCurrentAuthority { () throws -> Int in
            throw Failure.injectedWrite
        })
        XCTAssertTrue(try contender.tryAcquireExisting())
        contender.release()
    }

    @MainActor
    func testSigningAuthorityGateRejectsRevocationExpirationAndReleasedExecution() async throws {
        for (index, invalidation) in ["revoked", "expired", "released", "removedWallet"].enumerated() {
            let fixture = try makeTransactionFixture(id: 76_120 + index, host: "signing-gate-\(index).example")
            let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            let execution = try await reviewedExecution(claim)
            defer { execution.releaseLease() }
            XCTAssertEqual(execution.permit.withCurrentAuthority { true }, true)
            switch invalidation {
            case "revoked":
                guard case .snapshot(let current) = await bridge.configurationSnapshot(
                    configurationKey: fixture.request.configurationKey, profileIdentifier: nil
                ), case .revoked = await bridge.revoke(
                    configurationKey: fixture.request.configurationKey, provider: .ethereum,
                    attempt: attempt(for: 77_120 + index), expected: current.version, profileIdentifier: nil
                ) else { return XCTFail("Expected provider revocation") }
            case "expired":
                clock.now = execution.executionDeadline
            case "removedWallet":
                let account = try XCTUnwrap(execution.request.authorizedAccount)
                try removalStore().withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) {}
            default:
                execution.releaseLease()
            }
            var entered = false
            let result = execution.permit.withCurrentAuthority {
                entered = true
                return 42
            }
            XCTAssertNil(result, invalidation)
            XCTAssertFalse(entered, invalidation)
        }
    }

    @MainActor
    func testAuthorizationRejectsAbandonedExpiredAndRevokedClaims() async throws {
        for (index, invalidation) in ["abandoned", "expired", "revoked"].enumerated() {
            let fixture = try makeTransactionFixture(id: 76_020 + index, host: "boundary-\(index).example")
            let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            XCTAssertTrue(claim.adoptForExecution())
            let approval = try reviewedApproval(claim)
            switch invalidation {
            case "abandoned":
                let abandoned = await bridge.abandon(claim: claim)
                XCTAssertEqual(abandoned, .persisted)
            case "expired":
                clock.now = claim.executionDeadline
            default:
                guard case .snapshot(let authority) = await bridge.configurationSnapshot(configurationKey: fixture.request.configurationKey, profileIdentifier: nil),
                      case .revoked = await bridge.revoke(configurationKey: fixture.request.configurationKey, provider: .ethereum, attempt: attempt(for: 77_020 + index), expected: authority.version, profileIdentifier: nil) else { return XCTFail("Expected revocation") }
            }
            let result = await bridge.authorize(claim: claim, approval: approval)
            XCTAssertEqual(result, .ownershipLost)
            claim.releaseUnapproved()
        }
    }

    @MainActor
    func testTransferredClaimAliasesCannotReleaseOrCompleteTheirPermit() async throws {
        let fixture = try makeTransactionFixture(id: 990)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        let copy = claim
        let execution = try await reviewedExecution(claim)
        let abandoned = await bridge.abandon(claim: copy)
        let completion = await bridge.complete(claim: copy, resolution: .failure(.userRejected))
        XCTAssertEqual(abandoned, .ownershipLost)
        XCTAssertEqual(completion, .ownershipLost)
        XCTAssertFalse(copy.adoptForExecution())
        copy.releaseUnapproved()
        let competingLock = CrossProcessFileLock(fileURL: operationLockURL(handle))
        XCTAssertFalse(try competingLock.tryAcquireExisting())
        competingLock.release()
        let completed = await completeReviewedExecution(execution)
        XCTAssertEqual(completed, .persisted)
        let delivered = try responseJSON(await bridge.prepareResponseDelivery(
            id: handle.id, configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken, profileIdentifier: nil
        ))
        XCTAssertEqual(NSDictionary(dictionary: delivered), NSDictionary(dictionary: execution.response.json))
    }

    @MainActor
    func testConcurrentAuthorizationOfCopiedClaimHasOneOwner() async throws {
        let fixture = try makeTransactionFixture(id: 76_030)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        XCTAssertTrue(claim.adoptForExecution())
        let firstApproval = try reviewedApproval(claim)
        let secondApproval = try reviewedApproval(claim)
        let firstStore = makeBridge(clock: { [clock = clock!] in clock.now })
        let secondStore = makeBridge(clock: { [clock = clock!] in clock.now })
        let copiedClaim = claim
        async let firstResult = firstStore.authorize(claim: claim, approval: firstApproval)
        async let secondResult = secondStore.authorize(claim: copiedClaim, approval: secondApproval)
        let results = await [firstResult, secondResult]
        let permits = results.compactMap { result -> ExtensionBridge.ApprovedExecutionPermit? in
            guard case .authorized(let permit) = result else { return nil }
            return permit
        }
        XCTAssertEqual(permits.count, 1)
        XCTAssertEqual(results.filter { $0 == .ownershipLost }.count, 1)
        let permit = try XCTUnwrap(permits.first)
        copiedClaim.releaseUnapproved()
        let staleAbandon = await secondStore.abandon(claim: copiedClaim)
        XCTAssertEqual(staleAbandon, .ownershipLost)
        let competingLock = CrossProcessFileLock(fileURL: operationLockURL(handle))
        XCTAssertFalse(try competingLock.tryAcquireExisting())
        competingLock.release()
        XCTAssertTrue(permit.consumeExecution())
        XCTAssertFalse(permit.consumeExecution())
        let completion = try XCTUnwrap(ApprovedCompletion.failure(.userRejected, permit: permit))
        let completed = await firstStore.complete(permit: permit, result: completion)
        XCTAssertEqual(completed, .persisted)
    }

    @MainActor
    func testAuthorizationCompetesAtomicallyWithUnapprovedTermination() async throws {
        for (index, completes) in [false, true].enumerated() {
            let fixture = try makeTransactionFixture(id: 76_040 + index)
            let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            XCTAssertTrue(claim.adoptForExecution())
            let approval = try reviewedApproval(claim)
            let authorizer = makeBridge(clock: { [clock = clock!] in clock.now })
            let terminator = makeBridge(clock: { [clock = clock!] in clock.now })
            let copiedClaim = claim
            async let authorization = authorizer.authorize(claim: claim, approval: approval)
            async let termination = completes
                ? terminator.complete(claim: copiedClaim, resolution: .failure(.userRejected))
                : terminator.abandon(claim: copiedClaim)
            let (authorized, terminated) = await (authorization, termination)
            switch authorized {
            case .authorized(let permit):
                XCTAssertEqual(terminated, .ownershipLost)
                claim.releaseUnapproved()
                let lock = CrossProcessFileLock(fileURL: operationLockURL(handle))
                XCTAssertFalse(try lock.tryAcquireExisting())
                lock.release()
                XCTAssertTrue(permit.consumeExecution())
                let result = try XCTUnwrap(ApprovedCompletion.failure(.userRejected, permit: permit))
                let completed = await authorizer.complete(permit: permit, result: result)
                XCTAssertEqual(completed, .persisted)
            case .ownershipLost:
                XCTAssertEqual(terminated, .persisted)
                XCTAssertFalse(claim.adoptForExecution())
                guard case .found(let snapshot) = await bridge.load(handle: handle) else {
                    return XCTFail("Expected the winning terminal state")
                }
                XCTAssertEqual(snapshot.phase, completes ? .responded : .queued)
            case .retryablePersistenceFailure:
                XCTFail("An uncontended store must produce one lifecycle winner")
            }
        }
    }

    @MainActor
    func testAuthorizationRechecksDeadlineAfterProfileRead() async throws {
        let callbackClock = clock!
        let fixture = try makeTransactionFixture(id: 76_050)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        XCTAssertTrue(claim.adoptForExecution())
        let approval = try reviewedApproval(claim)
        clock.now = claim.executionDeadline.addingTimeInterval(-0.01)
        let reads = LockedTestValue(0)
        let expectedProfileURL = profileURL(handle.profileIdentifier)
        let authorizer = makeBridge(clock: { [clock = clock!] in clock.now }, readData: { url in
            let data = try Data(contentsOf: url)
            if url == expectedProfileURL {
                reads.withValue { $0 += 1 }
                callbackClock.now = claim.executionDeadline
            }
            return data
        })
        let authorized = await authorizer.authorize(claim: claim, approval: approval)
        XCTAssertGreaterThan(reads.value, 0)
        XCTAssertEqual(authorized, .ownershipLost)
        claim.releaseUnapproved()
        guard case .found(let recovered) = await bridge.load(handle: handle) else {
            return XCTFail("Expected expired request recovery")
        }
        XCTAssertEqual(recovered.phase, .queued)
    }

    @MainActor
    func testSigningAndPublicationRecheckDeadlineAfterProfileRead() async throws {
        for (index, boundary) in ["signing", "broadcast", "completion"].enumerated() {
            let fixture = try makeTransactionFixture(id: 76_052 + index, host: "read-deadline-\(index).example")
            let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            let approval = try reviewedApproval(claim)
            let deadline = claim.executionDeadline
            let callbackClock = clock!
            let expireDuringRead = LockedTestValue(false)
            let reads = LockedTestValue(0)
            let expectedProfileURL = profileURL(handle.profileIdentifier)
            let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
                clock: { callbackClock.now },
                atomicWrite: ApprovalStoreTestPersistence.write,
                readData: { url in
                    let data = try Data(contentsOf: url)
                    if expireDuringRead.value, url == expectedProfileURL {
                        reads.withValue { $0 += 1 }
                        callbackClock.now = deadline
                    }
                    return data
                }
            ))
            guard claim.adoptForExecution(),
                  case .authorized(let permit) = store.authorize(claim: claim, approval: approval),
                  permit.consumeExecution() else { return XCTFail("Expected approved execution") }
            defer { permit.releaseLease() }
            let broadcast: PreparedBroadcast?
            if boundary == "signing" {
                broadcast = nil
            } else {
                broadcast = try await preparedBroadcastForTesting(permit: permit, clock: { callbackClock.now })
            }
            clock.now = deadline.addingTimeInterval(-0.01)
            expireDuringRead.value = true
            switch boundary {
            case "signing":
                var entered = false
                let result = permit.withCurrentAuthority {
                    entered = true
                    return true
                }
                XCTAssertNil(result)
                XCTAssertFalse(entered)
            case "broadcast":
                let prepared = store.prepareBroadcast(permit: permit, broadcast: try XCTUnwrap(broadcast))
                guard case .ownershipLost = prepared else { return XCTFail("Expired execution must not checkpoint") }
            default:
                let completion = try XCTUnwrap(broadcast?.recoveryCompletion(for: permit))
                XCTAssertEqual(store.complete(permit: permit, result: completion), .ownershipLost)
            }
            XCTAssertGreaterThan(reads.value, 0, boundary)
        }
    }

    @MainActor
    func testDroppedPermitReleasesPhysicalLockDespiteRetainedClaimAliases() async throws {
        let fixture = try makeTransactionFixture(id: 76_060)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        let copiedClaim = claim
        XCTAssertTrue(claim.adoptForExecution())
        let approval = try reviewedApproval(claim)
        var permit: ExtensionBridge.ApprovedExecutionPermit?
        switch await bridge.authorize(claim: claim, approval: approval) {
        case .authorized(let authorized): permit = authorized
        default: return XCTFail("Expected an approved owner")
        }
        weak let retainedPermit = permit
        XCTAssertTrue(try XCTUnwrap(permit).consumeExecution())
        permit = nil
        XCTAssertNil(retainedPermit)
        copiedClaim.releaseUnapproved()
        let lock = CrossProcessFileLock(fileURL: operationLockURL(handle))
        XCTAssertTrue(try lock.tryAcquireExisting())
        lock.release()
        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .found(let recovered) = await observer.load(handle: handle) else {
            return XCTFail("Expected abandoned approved execution recovery")
        }
        XCTAssertEqual(recovered.phase, .queued)
        let replay = await observer.authorize(claim: copiedClaim, approval: approval)
        XCTAssertEqual(replay, .ownershipLost)
    }

    @MainActor
    func testExecutionBoundariesHoldOwnershipUntilTerminalPublication() async throws {
        for (index, boundary) in ["authorize", "checkpoint", "complete"].enumerated() {
            let fixture = try makeTransactionFixture(id: 991 + index * 2)
            let handle = try accepted(await bridge.enqueue(
                ingress: fixture.ingress, profileIdentifier: nil
            )).handle
            let sibling = try makeFixture(id: handle.id + 1, admissionDeadline: clock.now.addingTimeInterval(1))
            _ = try accepted(await bridge.enqueue(ingress: sibling.ingress, profileIdentifier: nil))
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            let approval = boundary == "authorize" ? try reviewedApproval(claim) : nil
            let permit = boundary == "authorize" ? nil : try await reviewedExecution(claim)
            var authorizedPermit: ExtensionBridge.ApprovedExecutionPermit?
            clock.now.addTimeInterval(2)
            let writes = LockedTestValue(0)
            let expectedOperationURL = operationLockURL(handle)
            let writer = makeBridge(clock: { [clock = clock!] in clock.now }, atomicWrite: { data, url in
                writes.withValue { $0 += 1 }
                let competingLock = CrossProcessFileLock(fileURL: expectedOperationURL)
                let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
                let records = try XCTUnwrap(profile["records"] as? [[String: Any]])
                let record = try XCTUnwrap(records.first { $0["id"] as? Int == handle.id })
                let state = try XCTUnwrap(record["state"] as? [String: Any])
                XCTAssertEqual(try competingLock.tryAcquireExisting(), state["completed"] != nil)
                competingLock.release()
                try ApprovalStoreTestPersistence.write(data, url)
            })
            if boundary == "authorize" {
                XCTAssertTrue(claim.adoptForExecution())
                guard case .authorized(let value) = await writer.authorize(claim: claim, approval: try XCTUnwrap(approval)) else {
                    return XCTFail("Expected direct authorization after maintenance")
                }
                authorizedPermit = value
            } else if boundary == "checkpoint" {
                let result = await prepareReviewedBroadcast(try XCTUnwrap(permit), in: writer)
                XCTAssertEqual(result, .persisted)
            } else {
                let result = await completeReviewedExecution(try XCTUnwrap(permit), in: writer)
                XCTAssertEqual(result, .persisted)
            }
            XCTAssertGreaterThan(writes.value, 0)
            let records = try XCTUnwrap(try storedProfile()["records"] as? [[String: Any]])
            let expired = try XCTUnwrap(records.first { $0["id"] as? Int == sibling.request.id })
            XCTAssertNotNil((expired["state"] as? [String: Any])?["completed"])
            let live = try XCTUnwrap(records.first { $0["id"] as? Int == handle.id })
            let expectedPhase = boundary == "authorize" ? "claimed" : boundary == "checkpoint" ? "broadcastPrepared" : "completed"
            XCTAssertNotNil((live["state"] as? [String: Any])?[expectedPhase])
            if let authorizedPermit {
                let abandoned = await bridge.abandon(permit: authorizedPermit)
                XCTAssertEqual(abandoned, .persisted)
            } else if boundary != "complete" {
                let result = await completeReviewedExecution(try XCTUnwrap(permit), in: bridge)
                XCTAssertEqual(result, .persisted)
            }
        }
    }

    @MainActor
    func testExecutorDropsPhysicalLeaseAfterAmbiguousWritesWithoutRepeatingWork() async throws {
        for (operationIndex, broadcasts) in [false, true].enumerated() {
            for (failureIndex, persistsBeforeFailure) in [false, true].enumerated() {
                let fixture = try makeTransactionFixture(id: 997 + operationIndex * 2 + failureIndex)
                let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
                let claim = try approvalClaim(await bridge.claim(handle: handle))
                guard case .found(let snapshot) = await bridge.load(handle: handle) else { throw Failure.expectedValue }
                let consent = try Self.reviewedConsent(snapshot, approvedAt: clock.now)
                let approval = try consent.resolve(
                    context: approvalResolutionContextForTesting(
                        action: consent.intent.action,
                        decision: consent.decision,
                        accounts: [try XCTUnwrap(snapshot.request?.authorizedAccount).specificAccount]
                    )
                ).get()
                let processor = StorageExecutionProcessor(broadcasts: broadcasts)
                let sender = StorageBroadcastSender()
                let writer = makeBridge(clock: { [clock = clock!] in clock.now }, atomicWrite: { data, url in
                    if persistsBeforeFailure { try ApprovalStoreTestPersistence.write(data, url) }
                    throw Failure.injectedWrite
                })
                let executor = DurableApprovalExecutor(
                    store: writer,
                    environment: .init(
                        requestProcessor: processor,
                        broadcastSender: sender,
                        clock: { [clock = clock!] in clock.now }
                    )
                )
                let signing = makeWalletSigningSessionForTesting(authorization: .init(
                    handle: claim.handle,
                    approvedAccount: try XCTUnwrap(approval.approval.signingAccount),
                    signingDeadline: claim.executionDeadline
                ))
                let result = await executor.execute(claim: claim, prepare: { _ in
                    .ready(consent: consent, signing: .unlocked(signing))
                }, resolve: { _ in .approved(approval) })
                XCTAssertEqual(result, .retryablePersistenceFailure)
                XCTAssertEqual(processor.calls, 1)
                XCTAssertEqual(sender.calls, 0)
                let competingLock = CrossProcessFileLock(fileURL: operationLockURL(handle))
                XCTAssertTrue(try competingLock.tryAcquireExisting())
                competingLock.release()
                guard case .found(let recovered) = await bridge.load(handle: handle) else {
                    return XCTFail("Expected recovered request")
                }
                XCTAssertEqual(recovered.phase, persistsBeforeFailure ? .responded : .queued)
                if persistsBeforeFailure {
                    let delivered = try responseJSON(await bridge.prepareResponseDelivery(
                        id: handle.id, configurationKey: fixture.request.configurationKey,
                        requestToken: handle.requestToken, profileIdentifier: nil
                    ))
                    XCTAssertEqual((delivered["error"] as? [String: Any])?["code"] as? Int,
                        broadcasts ? ProviderResponseError.transactionSubmissionUnknownCode : 4001)
                    XCTAssertEqual(delivered["approvalCommitted"] as? Bool, true)
                }
            }
        }
    }

    @MainActor
    func testOrdinaryClaimDeadlineRoundTripsAndEndsAtBroadcastCheckpoint() async throws {
        let fixture = try makeTransactionFixture(id: 989)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress, profileIdentifier: nil
        )).handle
        let firstClaim = try approvalClaim(await bridge.claim(handle: handle))
        defer { firstClaim.releaseUnapproved() }
        let claimedState = try firstStoredState("claimed")
        let approval = try XCTUnwrap(claimedState["approval"] as? [String: Any])
        let ordinary = try XCTUnwrap(approval["ordinary"] as? [String: Any])
        XCTAssertEqual(ordinary["deadline"] as? Date, firstClaim.executionDeadline)
        let claimedRecords = try XCTUnwrap(try storedProfile()["records"] as? [[String: Any]])
        XCTAssertNil(claimedRecords.first?["executionDeadline"])

        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        let firstPermit = try await reviewedExecution(firstClaim)
        let rolledBack = await observer.abandon(permit: firstPermit.permit)
        XCTAssertEqual(rolledBack, .persisted)
        _ = try firstStoredState("pending")
        clock.now.addTimeInterval(1)
        let nextClaim = try approvalClaim(await observer.claim(handle: handle))
        defer { nextClaim.releaseUnapproved() }
        XCTAssertGreaterThan(nextClaim.executionDeadline, firstClaim.executionDeadline)
        let nextPermit = try await reviewedExecution(nextClaim)
        let checkpointed = await prepareReviewedBroadcast(nextPermit, in: observer)
        XCTAssertEqual(checkpointed, .persisted)
        let broadcastState = try firstStoredState("broadcastPrepared")
        let broadcastApproval = try XCTUnwrap(broadcastState["approval"] as? [String: Any])
        let ordinaryBroadcast = try XCTUnwrap(broadcastApproval["ordinary"] as? [String: Any])
        XCTAssertTrue(ordinaryBroadcast.isEmpty)

        clock.now = nextClaim.executionDeadline.addingTimeInterval(1)
        let completed = await completeReviewedExecution(nextPermit, in: observer)
        XCTAssertEqual(completed, .persisted)
        let completedRecords = try XCTUnwrap(try storedProfile()["records"] as? [[String: Any]])
        XCTAssertNil(completedRecords.first?["executionDeadline"])
        _ = try firstStoredState("completed")
    }

    @MainActor
    func testExecutionWriteFailuresRecoverAccordingToThePersistedPhase()
        async throws {
        for (operationIndex, checkpointsBroadcast) in [false, true].enumerated() {
            for (failureIndex, persistsBeforeFailure) in [false, true].enumerated() {
                bridge = makeBridge(clock: { [clock = clock!] in clock.now })
                let fixture = try makeTransactionFixture(id: 740 + operationIndex * 2 + failureIndex)
                let handle = try accepted(await bridge.enqueue(
                    ingress: fixture.ingress,
                    profileIdentifier: nil
                )).handle
                let claim = try approvalClaim(await bridge.claim(handle: handle))
                let permit = try await reviewedExecution(claim)
                let failingWriter = makeBridge(
                    clock: { [clock = clock!] in clock.now },
                    atomicWrite: { data, url in
                        if persistsBeforeFailure {
                            try ApprovalStoreTestPersistence.write(data, url)
                        }
                        throw Failure.injectedWrite
                    }
                )
                let expectedResponse = checkpointsBroadcast
                    ? permit.recoveryResponse
                    : permit.response
                let result: ExtensionBridge.StoreMutationResult
                if checkpointsBroadcast {
                    result = await prepareReviewedBroadcast(permit, in: failingWriter)
                } else {
                    result = await completeReviewedExecution(permit, in: failingWriter)
                }
                XCTAssertEqual(result, .retryablePersistenceFailure)
                let observer = makeBridge(clock: { [clock = clock!] in clock.now })
                guard case .found(let held) = await observer.load(handle: handle) else {
                    return XCTFail("Expected retained failed execution")
                }
                XCTAssertEqual(
                    held.phase,
                    checkpointsBroadcast ? .approving : persistsBeforeFailure ? .responded : .queued
                )

                permit.releaseLease()
                let restarted = makeBridge(clock: { [clock = clock!] in clock.now })
                guard case .found(let recovered) = await restarted.load(handle: handle) else {
                    return XCTFail("Expected recoverable persisted phase")
                }
                XCTAssertEqual(recovered.phase, persistsBeforeFailure ? .responded : .queued)
                if persistsBeforeFailure {
                    let response = try responseJSON(await restarted.prepareResponseDelivery(
                        id: handle.id,
                        configurationKey: fixture.request.configurationKey,
                        requestToken: handle.requestToken,
                        profileIdentifier: nil
                    ))
                    XCTAssertEqual(
                        NSDictionary(dictionary: response),
                        NSDictionary(dictionary: expectedResponse.json)
                    )
                }
            }
        }
    }

    func testContainerStoreSynchronizesEveryCreatedAncestorAndRetriesResponseBarrier() throws {
        let container = rootURL.standardizedFileURL
        let library = container.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let storeRoot = support.appendingPathComponent("BigWalletExtensionBridge", isDirectory: true)
        let profiles = storeRoot.appendingPathComponent("profiles-v9", isDirectory: true)
        let expectedPaths = [profiles, storeRoot, support, library, container].map(\.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))

        var operations = DurableProfilePersistence.Operations.live
        let openDirectory = operations.openDirectory
        let syncDirectory = operations.syncDirectory
        let directoryPaths = LockedTestValue([Int32: String]())
        let openedPaths = LockedTestValue([String]())
        let synchronizedPaths = LockedTestValue([String]())
        let failBoundarySynchronization = LockedTestValue(false)
        operations.openDirectory = { path in
            let descriptor = try openDirectory(path)
            directoryPaths.withValue { $0[descriptor] = path }
            openedPaths.withValue { $0.append(path) }
            return descriptor
        }
        operations.syncDirectory = { descriptor in
            let path = try XCTUnwrap(directoryPaths.value[descriptor])
            synchronizedPaths.withValue { $0.append(path) }
            if failBoundarySynchronization.value, path == container.path {
                throw Failure.injectedWrite
            }
            try syncDirectory(descriptor)
        }
        let store = ExtensionRequestFileStore(
            containerURL: container,
            dependencies: .init(clock: { [clock = clock!] in clock.now }, persistenceOperations: operations)
        )
        let template = try makeFixture(id: 982)
        guard case .snapshot(let snapshot) = store.configurationSnapshot(configurationKey: template.request.configurationKey, profileIdentifier: nil) else { return XCTFail("Expected container authority") }
        let ledgerPaths = [storeRoot, support, library, container].map(\.path)
        XCTAssertEqual(openedPaths.value, ledgerPaths + expectedPaths)
        XCTAssertEqual(synchronizedPaths.value, ledgerPaths + expectedPaths)
        openedPaths.withValue { $0.removeAll() }
        synchronizedPaths.withValue { $0.removeAll() }
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: template.ingress.canonicalData) as? [String: Any])
        raw["authority"] = snapshot.version.json
        let fixture = try authorityFixture(raw)
        let handle = try accepted(store.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        XCTAssertEqual(openedPaths.value, expectedPaths)
        XCTAssertEqual(synchronizedPaths.value, expectedPaths)

        let expectedResponse = response(for: fixture.request)
        XCTAssertEqual(store.completeImmediate(handle: handle, resolution: immediateResolution(for: fixture.request)), .persisted)
        openedPaths.withValue { $0.removeAll() }
        synchronizedPaths.withValue { $0.removeAll() }
        failBoundarySynchronization.value = true
        guard case .unavailable = store.prepareResponseDelivery(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        ) else { return XCTFail("Response reads must synchronize through the container boundary") }
        XCTAssertEqual(openedPaths.value, expectedPaths)
        XCTAssertEqual(synchronizedPaths.value, expectedPaths)

        openedPaths.withValue { $0.removeAll() }
        synchronizedPaths.withValue { $0.removeAll() }
        failBoundarySynchronization.value = false
        let recovered = try responseJSON(store.prepareResponseDelivery(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        ))
        XCTAssertEqual(recovered as NSDictionary, expectedResponse.json as NSDictionary)
        XCTAssertEqual(openedPaths.value, expectedPaths)
        XCTAssertEqual(synchronizedPaths.value, expectedPaths)
    }

    func testAmbiguousAdmissionReplayRequiresPublishedFileSynchronization() async throws {
        let fixture = try makeFixture(id: 983)
        try await assertAdmissionRetryRequiresSynchronization(
            original: fixture,
            retry: fixture,
            admissionKind: .replay
        )
    }

    func testAmbiguousManualAdmissionCoalescingRequiresPublishedFileSynchronization() async throws {
        let original = try makeManualFixture(
            id: 984,
            enqueueAttempt: attempt(for: 984),
            latestConfigurations: []
        )
        let retry = try makeManualFixture(
            id: 985,
            enqueueAttempt: attempt(for: 985),
            latestConfigurations: []
        )
        try await assertAdmissionRetryRequiresSynchronization(
            original: original,
            retry: retry,
            admissionKind: .coalesced
        )
    }

    func testAmbiguousCompletionAndResponseReadRequirePublishedFileSynchronization()
        async throws {
        let fixture = try makeFixture(id: 974)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let expected = response(for: fixture.request)
        let failSynchronization = LockedTestValue(true)
        let synchronizedURLs = LockedTestValue([URL]())
        let observer = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { data, url in
                try data.write(to: url, options: .atomic)
                throw Failure.injectedWrite
            },
            synchronizePublishedFile: { url in
                synchronizedURLs.withValue { $0.append(url) }
                if failSynchronization.value { throw Failure.injectedWrite }
                try ApprovalStoreTestPersistence.synchronize(url)
            }
        )

        let completion = await observer.completeImmediate(handle: handle, resolution: immediateResolution(for: fixture.request))
        XCTAssertEqual(completion, .retryablePersistenceFailure)
        XCTAssertEqual(try firstStoredState("completed")["acknowledged"] as? Bool, false)
        XCTAssertEqual(synchronizedURLs.value, [defaultProfileURL])
        guard case .unavailable = await observer.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ) else { return XCTFail("Visible response bytes must not bypass failed synchronization") }
        XCTAssertEqual(synchronizedURLs.value.count, 2)

        failSynchronization.value = false
        let recovered = try responseJSON(await observer.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(recovered as NSDictionary, expected.json as NSDictionary)
        XCTAssertEqual(synchronizedURLs.value.count, 3)
    }

    @MainActor
    func testRepeatedExecutionCommitSynchronizesWithoutRepeatingPublication()
        async throws {
        for (index, checkpointsBroadcast) in [false, true].enumerated() {
            let profileIdentifier = UUID()
            let fixture = try makeTransactionFixture(id: 975 + index)
            let handle = try accepted(await bridge.enqueue(
                ingress: try profileFixture(fixture, profileIdentifier: profileIdentifier).ingress,
                profileIdentifier: profileIdentifier
            )).handle
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            let permit = try await reviewedExecution(claim)
            defer { permit.releaseLease() }
            let expected = checkpointsBroadcast
                ? permit.recoveryResponse
                : permit.response
            let failSynchronization = LockedTestValue(true)
            let synchronizationAttempts = LockedTestValue(0)
            let publications = LockedTestValue(0)
            let expectedProfileURL = profileURL(profileIdentifier)
            let writer = makeBridge(
                clock: { [clock = clock!] in clock.now },
                atomicWrite: { data, url in
                    publications.withValue { $0 += 1 }
                    try data.write(to: url, options: .atomic)
                    throw Failure.injectedWrite
                },
                synchronizePublishedFile: { url in
                    synchronizationAttempts.withValue { $0 += 1 }
                    XCTAssertEqual(url, expectedProfileURL)
                    if failSynchronization.value { throw Failure.injectedWrite }
                    try ApprovalStoreTestPersistence.synchronize(url)
                }
            )
            func commit() async -> ExtensionBridge.StoreMutationResult {
                if checkpointsBroadcast {
                    return await prepareReviewedBroadcast(permit, in: writer)
                }
                return await completeReviewedExecution(permit, in: writer)
            }

            let first = await commit()
            XCTAssertEqual(first, .retryablePersistenceFailure)
            let repeated = await commit()
            XCTAssertEqual(repeated, .retryablePersistenceFailure)
            XCTAssertEqual(synchronizationAttempts.value, 1)
            let competingLock = CrossProcessFileLock(fileURL: operationLockURL(handle))
            XCTAssertEqual(try competingLock.tryAcquireExisting(), !checkpointsBroadcast)
            competingLock.release()

            failSynchronization.value = false
            let retried = await commit()
            XCTAssertEqual(retried, .persisted)
            XCTAssertEqual(synchronizationAttempts.value, 2)
            XCTAssertEqual(publications.value, 1)
            if !checkpointsBroadcast {
                XCTAssertTrue(try competingLock.tryAcquireExisting())
                competingLock.release()
            }
            permit.releaseLease()
            let recovered = try responseJSON(await bridge.prepareResponseDelivery(
                id: handle.id,
                configurationKey: fixture.request.configurationKey,
                requestToken: handle.requestToken,
                profileIdentifier: profileIdentifier
            ))
            XCTAssertEqual(recovered as NSDictionary, expected.json as NSDictionary)
        }
    }

    func testAmbiguousAndRepeatedAcknowledgmentRequirePublishedFileSynchronization()
        async throws {
        let fixture = try makeFixture(id: 977)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let completed = await bridge.completeImmediate(
            handle: handle,
            resolution: immediateResolution(for: fixture.request)
        )
        XCTAssertEqual(completed, .persisted)
        let failSynchronization = LockedTestValue(true)
        let synchronizationAttempts = LockedTestValue(0)
        let writer = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { data, url in
                try data.write(to: url, options: .atomic)
                throw Failure.injectedWrite
            },
            synchronizePublishedFile: { url in
                synchronizationAttempts.withValue { $0 += 1 }
                if failSynchronization.value { throw Failure.injectedWrite }
                try ApprovalStoreTestPersistence.synchronize(url)
            }
        )
        let first = await writer.acknowledgeResponse(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        )
        XCTAssertEqual(first, .retryablePersistenceFailure)
        XCTAssertEqual(try firstStoredState("completed")["acknowledged"] as? Bool, true)
        let repeated = await writer.acknowledgeResponse(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        )
        XCTAssertEqual(repeated, .retryablePersistenceFailure)
        XCTAssertEqual(synchronizationAttempts.value, 2)

        failSynchronization.value = false
        let retried = await writer.acknowledgeResponse(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        )
        XCTAssertEqual(retried, .persisted)
        XCTAssertEqual(synchronizationAttempts.value, 3)
        guard case .available(let listed) = await writer.list(profileIdentifier: nil) else {
            return XCTFail("Expected synchronized acknowledgment to remain readable")
        }
        XCTAssertTrue(listed.isEmpty)
    }

    @MainActor
    func testFailedUnrelatedProfileMutationPreservesBroadcastRecovery()
        async throws {
        let fixture = try makeTransactionFixture(id: 978)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let other = try makeFixture(id: 979)
        let otherHandle = try accepted(await bridge.enqueue(
            ingress: other.ingress,
            profileIdentifier: nil
        )).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        let permit = try await reviewedExecution(claim)
        defer { permit.releaseLease() }
        let recovery = permit.recoveryResponse
        let prepared = await prepareReviewedBroadcast(permit, in: bridge)
        XCTAssertEqual(prepared, .persisted)
        let failingWriter = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { data, url in
                try data.write(to: url, options: .atomic)
                throw Failure.injectedWrite
            },
            synchronizePublishedFile: { _ in throw Failure.injectedWrite }
        )
        let rejected = await failingWriter.reject(handle: otherHandle)
        XCTAssertEqual(rejected, .retryablePersistenceFailure)
        let repeatedCheckpoint = await prepareReviewedBroadcast(permit, in: failingWriter)
        XCTAssertEqual(repeatedCheckpoint, .retryablePersistenceFailure)

        permit.releaseLease()
        let restarted = makeBridge(clock: { [clock = clock!] in clock.now })
        let recovered = try responseJSON(await restarted.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(recovered as NSDictionary, recovery.json as NSDictionary)
        let otherResponse = try responseJSON(await restarted.prepareResponseDelivery(
            id: otherHandle.id,
            configurationKey: other.request.configurationKey,
            requestToken: otherHandle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual((otherResponse["error"] as? [String: Any])?["code"] as? Int, 4001)
    }

    @MainActor
    func testBroadcastIsNotSentWhenCheckpointPublicationCannotBeSynchronized() async throws {
        let fixture = try makeTransactionFixture(id: 980)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        guard case .found(let snapshot) = await bridge.load(handle: handle) else { throw Failure.expectedValue }
        let consent = try Self.reviewedConsent(snapshot, approvedAt: clock.now)
        let approval = try consent.resolve(
            context: approvalResolutionContextForTesting(
                action: consent.intent.action,
                decision: consent.decision,
                accounts: [try XCTUnwrap(snapshot.request?.authorizedAccount).specificAccount]
            )
        ).get()
        let synchronizationAttempts = LockedTestValue(0)
        let synchronize: @Sendable (URL) throws -> Void = { _ in
            synchronizationAttempts.withValue { $0 += 1 }
            throw Failure.injectedWrite
        }
        let writer = makeBridge(clock: { [clock = clock!] in clock.now }, atomicWrite: { data, url in
            try data.write(to: url, options: .atomic)
            try synchronize(url)
        }, synchronizePublishedFile: synchronize)
        let processor = StorageExecutionProcessor(broadcasts: true)
        let sender = StorageBroadcastSender()
        let executor = DurableApprovalExecutor(
            store: writer,
            environment: .init(
                requestProcessor: processor,
                broadcastSender: sender,
                clock: { [clock = clock!] in clock.now }
            )
        )
        let signing = makeWalletSigningSessionForTesting(authorization: .init(
            handle: claim.handle,
            approvedAccount: try XCTUnwrap(approval.approval.signingAccount),
            signingDeadline: claim.executionDeadline
        ))
        let result = await executor.execute(claim: claim, prepare: { _ in
            .ready(consent: consent, signing: .unlocked(signing))
        }, resolve: { _ in .approved(approval) })
        XCTAssertEqual(result, .retryablePersistenceFailure)
        XCTAssertEqual(synchronizationAttempts.value, 1)
        XCTAssertEqual(processor.calls, 1)
        XCTAssertEqual(sender.calls, 0)
        let recovered = try responseJSON(await bridge.prepareResponseDelivery(
            id: handle.id, configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken, profileIdentifier: nil
        ))
        XCTAssertEqual((recovered["error"] as? [String: Any])?["code"] as? Int, ProviderResponseError.transactionSubmissionUnknownCode)
        XCTAssertEqual(recovered["approvalCommitted"] as? Bool, true)
    }

    func testRepeatedNativeReceiptRequiresPublishedFileSynchronization()
        async throws {
        let fixture = try makeFixture(id: 981)
        let admission = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let owner = storedRequestNativeOwner()
        let receipt = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            owner: owner
        )
        XCTAssertEqual(receipt, .persisted)
        let failSynchronization = LockedTestValue(true)
        let observer = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { _, _ in XCTFail("An exact native retry must not rewrite the profile") },
            synchronizePublishedFile: { url in
                if failSynchronization.value { throw Failure.injectedWrite }
                try ApprovalStoreTestPersistence.synchronize(url)
            }
        )
        for expected in [ExtensionBridge.StoreMutationResult.retryablePersistenceFailure, .persisted] {
            let repeatedReceipt = await observer.recordNativeDeliveryReceipt(
                handle: admission.handle,
                nativeDeliveryNonce: admission.nativeDeliveryNonce,
                owner: owner
            )
            XCTAssertEqual(repeatedReceipt, expected)
            failSynchronization.value = false
        }
    }

    @MainActor
    func testNativePreparedResultsMayCommitAfterSigningDeadline() async throws {
        for (index, checkpointsBroadcast) in [false, true].enumerated() {
            let execution = try await makeExecutableNativePermit(id: 76_070 + index)
            defer { execution.permit.releaseLease() }
            let permit = execution.permit.permit
            XCTAssertTrue(permit.isSigningAuthorized)
            clock.now = permit.signingDeadline.addingTimeInterval(1)
            XCTAssertFalse(permit.isSigningAuthorized)
            XCTAssertTrue(permit.isExecuting)

            if checkpointsBroadcast {
                let checkpoint = await prepareReviewedBroadcast(execution.permit)
                XCTAssertEqual(checkpoint, .persisted)
                clock.now = permit.executionDeadline
            }
            let completed = await completeReviewedExecution(execution.permit)
            XCTAssertEqual(completed, .persisted)
            let response = try responseJSON(await bridge.prepareResponseDelivery(
                id: execution.handle.id,
                configurationKey: execution.request.configurationKey,
                requestToken: execution.handle.requestToken,
                profileIdentifier: nil
            ))
            XCTAssertEqual(response as NSDictionary, execution.permit.response.json as NSDictionary)
            XCTAssertEqual(response["approvalCommitted"] as? Bool, true)
        }
    }

    @MainActor
    func testNativeAuthorizationRequiresObservationTime() async throws {
        let approvedAt = clock.now
        let fixture = try makeTransactionFixture(
            id: 76_080, admissionDeadline: approvedAt.addingTimeInterval(100)
        )
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress, profileIdentifier: nil
        )).handle
        let delivered = try await recordNativeDelivery(handle: handle)
        XCTAssertEqual(delivered, .persisted)
        clock.now = approvedAt.addingTimeInterval(10)
        guard case .claimed(let claim) = await claimDeliveredNativeExecution(
            in: bridge, handle: handle, approvedAt: approvedAt
        ) else { return XCTFail("Expected native claim") }
        defer { claim.releaseUnapproved() }
        let observedAt = try nativeApproval(claim).context.observedAt
        let approval = try reviewedApproval(claim)
        XCTAssertTrue(claim.adoptForExecution())

        clock.now = observedAt.addingTimeInterval(-0.01)
        XCTAssertGreaterThan(clock.now, approval.approvedAt)
        XCTAssertTrue(claim.authority.isWithinClaimLifetime(at: clock.now))
        let rejected = await bridge.authorize(claim: claim, approval: approval)
        XCTAssertEqual(rejected, .ownershipLost)

        clock.now = observedAt
        guard case .authorized(let permit) = await bridge.authorize(claim: claim, approval: approval) else {
            return XCTFail("Execution must remain eligible at its observation time")
        }
        defer { permit.releaseLease() }
        XCTAssertTrue(permit.consumeExecution())
    }

    @MainActor
    func testNativeCommitRejectsClockRollbackBeforeObservation() async throws {
        for (index, checkpointsBroadcast) in [false, true].enumerated() {
            for (offsetIndex, offset) in [-0.01, 0.0].enumerated() {
                let execution = try await makeExecutableNativePermit(id: 76_090 + index * 2 + offsetIndex)
                defer { execution.permit.releaseLease() }
                guard case .native(_, let context) = execution.permit.authority else {
                    return XCTFail("Expected native execution authority")
                }
                clock.now = context.observedAt.addingTimeInterval(offset)
                XCTAssertEqual(execution.permit.permit.isExecuting, offset == 0)
                let result = checkpointsBroadcast
                    ? await prepareReviewedBroadcast(execution.permit)
                    : await completeReviewedExecution(execution.permit)
                XCTAssertEqual(result, offset == 0 ? .persisted : .ownershipLost)
            }
        }
    }

    @MainActor
    func testOrdinaryCommitRejectsClockRollbackBeyondClaimLifetime() async throws {
        for (index, checkpointsBroadcast) in [false, true].enumerated() {
            for (offsetIndex, offset) in [-0.01, 0.0].enumerated() {
                let fixture = try makeTransactionFixture(id: 76_100 + index * 2 + offsetIndex)
                let handle = try accepted(await bridge.enqueue(
                    ingress: fixture.ingress, profileIdentifier: nil
                )).handle
                let claim = try approvalClaim(await bridge.claim(handle: handle))
                let execution = try await reviewedExecution(claim)
                defer { execution.releaseLease() }
                clock.now = claim.executionDeadline.addingTimeInterval(-ExtensionBridge.executionLifetime + offset)
                XCTAssertTrue(execution.permit.isExecuting)
                let result = checkpointsBroadcast
                    ? await prepareReviewedBroadcast(execution)
                    : await completeReviewedExecution(execution)
                XCTAssertEqual(result, offset == 0 ? .persisted : .ownershipLost)
            }
        }
    }

    @MainActor
    func testExecutionDeadlineRejectsCommitAtExactStoreBoundary()
        async throws {
        for (index, checkpointsBroadcast) in [false, true].enumerated() {
            let fixture = try makeTransactionFixture(id: 735 + index)
            let handle = try accepted(await bridge.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: nil
            )).handle
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            let permit = try await reviewedExecution(claim)
            let deadline = claim.executionDeadline
            clock.now = deadline

            let result: ExtensionBridge.StoreMutationResult
            if checkpointsBroadcast {
                result = await prepareReviewedBroadcast(permit, in: bridge)
            } else {
                result = await completeReviewedExecution(permit, in: bridge)
            }

            XCTAssertEqual(result, .ownershipLost)
            guard case .found(let retained) = await bridge.load(
                      handle: handle
                  ) else {
                return XCTFail("Expected retained execution")
            }
            XCTAssertEqual(retained.phase, checkpointsBroadcast ? .approving : .queued)
            let rollback = await bridge.abandon(permit: permit.permit)
            XCTAssertEqual(rollback, checkpointsBroadcast ? .persisted : .ownershipLost)
        }
    }

    func testExpiredHeldClaimRetainsOwnershipButCannotComplete() async throws {
        let fixture = try makeFixture(id: 42)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        clock.now.addTimeInterval(ExtensionBridge.requestTTL - 1)
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        clock.now.addTimeInterval(ExtensionBridge.requestTTL * 2)

        guard case .found(let active) = await bridge.load(handle: handle) else {
            return XCTFail("Expected active approval")
        }
        XCTAssertEqual(active.phase, .approving)

        XCTAssertTrue(claim.adoptForExecution())
        let completion = await bridge.complete(claim: claim, resolution: immediateResolution(for: fixture.request))
        XCTAssertEqual(completion, .ownershipLost)
        claim.releaseUnapproved()
    }

    @MainActor
    func testHeldPreparedBroadcastDoesNotExpireUntilItsLeaseEnds() async throws {
        let fixture = try makeTransactionFixture(id: 43)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        var permit: ReviewedExecution? = try await reviewedExecution(claim)
        _ = try XCTUnwrap(permit).recoveryResponse
        let preparation = await prepareReviewedBroadcast(try XCTUnwrap(permit), in: bridge)
        XCTAssertEqual(preparation, .persisted)
        clock.now.addTimeInterval(ExtensionBridge.requestTTL * 2)

        guard case .pending = await bridge.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ) else { return XCTFail("Expected held prepared broadcast") }

        permit?.releaseLease()
        permit = nil

        let delivered = try responseJSON(await bridge.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(
            (delivered["error"] as? [String: Any])?["code"] as? Int,
            ProviderResponseError.transactionSubmissionUnknownCode
        )
    }

    @MainActor
    func testExpiredNativeDeadlinePreventsBroadcastCheckpoint() async throws {
        let fixture = try makeTransactionFixture(id: 44)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        clock.now.addTimeInterval(ExtensionBridge.requestTTL - 1)
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        var permit: ReviewedExecution? = try await reviewedExecution(claim)
        clock.now.addTimeInterval(2)
        _ = try XCTUnwrap(permit).recoveryResponse
        let preparation = await prepareReviewedBroadcast(try XCTUnwrap(permit), in: bridge)
        XCTAssertEqual(preparation, .ownershipLost)
        guard case .pending = await bridge.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ) else { return XCTFail("Expected checkpoint ownership") }
        permit?.releaseLease()
        permit = nil
        let expired = try responseJSON(await bridge.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual((expired["error"] as? [String: Any])?["code"] as? Int, 4001)
    }

    @MainActor
    func testDroppedPreparedBroadcastCompletesWithUnknownSubmissionResponse() async throws {
        let fixture = try makeTransactionFixture(id: 50)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        var claim: ExtensionBridge.ApprovalClaim? = try approvalClaim(
            await bridge.claim(handle: handle)
        )
        var permit: ReviewedExecution? = try await reviewedExecution(try XCTUnwrap(claim))
        _ = try XCTUnwrap(permit).recoveryResponse
        let preparation = await prepareReviewedBroadcast(try XCTUnwrap(permit), in: bridge)
        XCTAssertEqual(preparation, .persisted)
        permit?.releaseLease()
        permit = nil
        claim = nil

        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        let delivered = try responseJSON(await observer.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(
            (delivered["error"] as? [String: Any])?["code"] as? Int,
            ProviderResponseError.transactionSubmissionUnknownCode
        )
        XCTAssertNotNil((delivered["error"] as? [String: Any])?["data"] as? [String: String])
        let retry = try accepted(await observer.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(retry.handle, handle)
        XCTAssertFalse(retry.approvalRequired)
    }

    @MainActor
    func testBroadcastRejectionPreservesFullRangeRPCErrorCodes() async throws {
        for (index, code) in [9_007_199_254_740_992, -9_007_199_254_740_992, Int.min, Int.max].enumerated() {
            let fixture = try makeTransactionFixture(id: 80 + index)
            let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            let execution = try await reviewedExecution(claim)
            let checkpoint = await prepareReviewedBroadcast(execution)
            XCTAssertEqual(checkpoint, .persisted)
            let sender = StorageBroadcastSender()
            sender.ethereumResult = .failure(.rpc(.serverError(code, "Rejected", dataJSON: #"{"reason":"custom"}"#)))
            let dispatched = await execution.broadcast?.dispatch(using: try XCTUnwrap(execution.dispatch), sender: sender)
            let rejection = try XCTUnwrap(dispatched)
            let completion = await completeReviewedExecution(execution, result: rejection)
            XCTAssertEqual(completion, .persisted)
            XCTAssertEqual(sender.calls, 1)
            let delivered = try responseJSON(await bridge.prepareResponseDelivery(
                id: handle.id, configurationKey: fixture.request.configurationKey,
                requestToken: handle.requestToken, profileIdentifier: nil
            ))
            let error = try XCTUnwrap(delivered["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, code)
            XCTAssertEqual(error["message"] as? String, "Rejected")
            XCTAssertEqual(error["data"] as? [String: String], ["reason": "custom"])
            XCTAssertEqual(delivered["approvalCommitted"] as? Bool, true)
        }
    }

    @MainActor
    func testNestedResponseDeliveryPreservesBoundaryAndDrainsCompletedQueue() async throws {
        for (index, scenario) in [(61, false), (62, false), (61, true), (62, true)].enumerated() {
            let (depth, broadcast) = scenario
            let fixture = try makeTransactionFixture(id: 75_000 + index)
            let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            let execution = try await reviewedExecution(claim)
            let payload = String(repeating: "{\"value\":", count: depth) + "null" + String(repeating: "}", count: depth)
            let result = try XCTUnwrap(ApprovedCompletion.failure(.init(message: "Rejected", code: -32_000, context: .dataJSON(payload)), permit: execution.permit))
            let response = try XCTUnwrap(result.response(for: execution.permit))
            XCTAssertEqual(ExtensionRequestProfileCodec.exactResponseData(response) != nil, depth == 61)
            if broadcast {
                let prepared = await prepareReviewedBroadcast(execution)
                XCTAssertEqual(prepared, .persisted)
            }
            let completion = await completeReviewedExecution(execution, result: result)
            XCTAssertEqual(completion, .persisted)
            let observer = makeBridge(clock: { [clock = clock!] in clock.now })
            guard case .response(let envelope) = await observer.prepareResponseDelivery(
                id: handle.id, configurationKey: fixture.request.configurationKey,
                requestToken: handle.requestToken, profileIdentifier: nil
            ) else { return XCTFail("Expected durable response delivery") }
            let wire = try XCTUnwrap(WireProtocol.object(.nativeDelivery, value: envelope.json))
            let delivered = try XCTUnwrap(wire.json["response"] as? [String: Any])
            XCTAssertEqual(delivered["approvalCommitted"] as? Bool, true)
            if depth == 61 || broadcast {
                let expected = depth == 61 ? response : execution.recoveryResponse
                XCTAssertEqual(ExtensionBridge.payloadData(delivered, options: [.sortedKeys]), ExtensionBridge.payloadData(expected.json, options: [.sortedKeys]))
            } else {
                let error = try XCTUnwrap(delivered["error"] as? [String: Any])
                XCTAssertEqual(error["code"] as? Int, ProviderResponseError.internalErrorCode)
                XCTAssertNil(error["data"])
            }
            let acknowledged = await observer.acknowledgeResponse(handle: handle, configurationKey: fixture.request.configurationKey)
            XCTAssertEqual(acknowledged, .persisted)
            guard case .available(let listed) = await observer.list(profileIdentifier: nil) else { return XCTFail("Expected queue") }
            XCTAssertTrue(listed.isEmpty)
        }
    }

    @MainActor
    func testOversizedBroadcastCompletionPreservesRecoveryResponse() async throws {
        let fixture = try makeTransactionFixture(id: 51)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        let execution = try await reviewedExecution(claim)
        let oversized = try XCTUnwrap(ApprovedCompletion.failure(.init(
            message: String(repeating: "x", count: ExtensionBridge.maximumPayloadBytes),
            code: ProviderResponseError.internalErrorCode
        ), permit: execution.permit))
        let prepared = await prepareReviewedBroadcast(execution)
        XCTAssertEqual(prepared, .persisted)
        let completed = await completeReviewedExecution(execution, result: oversized)
        XCTAssertEqual(completed, .persisted)
        let delivered = try responseJSON(await bridge.prepareResponseDelivery(
            id: handle.id, configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken, profileIdentifier: nil
        ))
        XCTAssertEqual(delivered as NSDictionary, execution.recoveryResponse.json as NSDictionary)
        XCTAssertEqual(delivered["approvalCommitted"] as? Bool, true)
    }

    @MainActor
    func testOversizedApprovedCompletionPreservesCommittedMarker() async throws {
        let fixture = try makeTransactionFixture(id: 52)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        let execution = try await reviewedExecution(claim)
        let oversized = try XCTUnwrap(ApprovedCompletion.failure(.init(
            message: String(repeating: "x", count: ExtensionBridge.maximumPayloadBytes),
            code: ProviderResponseError.internalErrorCode
        ), permit: execution.permit))
        let completed = await completeReviewedExecution(execution, result: oversized)
        XCTAssertEqual(completed, .persisted)
        let delivered = try responseJSON(await bridge.prepareResponseDelivery(
            id: handle.id, configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken, profileIdentifier: nil
        ))
        XCTAssertEqual(delivered["approvalCommitted"] as? Bool, true)
        XCTAssertEqual((delivered["error"] as? [String: Any])?["code"] as? Int, ProviderResponseError.internalErrorCode)
        XCTAssertNil((delivered["error"] as? [String: Any])?["data"])
    }

    func testCompletedResponseRemainsReadableUntilExpiryOrEviction() async throws {
        let fixture = try makeFixture(id: 60)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let completion = await bridge.completeImmediate(
            handle: handle,
            resolution: immediateResolution(for: fixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        let first = try responseJSON(await bridge.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        let repeated = try responseJSON(await bridge.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(first["result"] as? String, repeated["result"] as? String)
    }

    func testLargeBackwardClockCorrectionNormalizesPendingForListAndEnqueue() async throws {
        let first = try makeFixture(id: 61)
        let firstHandle = try accepted(await bridge.enqueue(
            ingress: first.ingress,
            profileIdentifier: nil
        )).handle
        clock.now.addTimeInterval(-60 * 60)

        guard case .available(let snapshots) = await bridge.list(
            profileIdentifier: nil
        ), let normalized = snapshots[firstHandle] else {
            return XCTFail("Expected normalized pending request")
        }
        XCTAssertEqual(normalized.createdAt, clock.now)
        _ = try accepted(await bridge.enqueue(
            ingress: try makeFixture(id: 62, host: "second.example").ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(try firstStoredCreatedAt(), clock.now)
        guard case .available = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected normalized profile to remain readable")
        }
    }

    func testBackwardClockCorrectionPreservesDeduplicationUntilAdmissionCutoff() async throws {
        let fixture = try makeFixture(id: 63)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let completion = await bridge.completeImmediate(
            handle: handle,
            resolution: immediateResolution(for: fixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        let admissionCutoff = clock.now.addingTimeInterval(
            ExtensionBridge.requestTTL +
                ExtensionBridge.admissionDeadlineFutureSkew
        )
        clock.now.addTimeInterval(
            -(ExtensionBridge.responseExpiry - 10 * 60)
        )

        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        _ = try responseJSON(await observer.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        clock.now.addTimeInterval(ExtensionBridge.responseExpiry)
        _ = try responseJSON(await observer.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        let retry = try accepted(await observer.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(retry.handle, handle)
        XCTAssertFalse(retry.approvalRequired)

        clock.now = admissionCutoff
        guard case .expired = await observer.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected retry expiry after deduplication cutoff") }
        guard case .missing = await observer.load(handle: handle) else {
            return XCTFail("Expected completed response retirement")
        }
    }

    func testLargeBackwardClockCorrectionFailsClosedAtCompletedByteCapacity() async throws {
        let completed = try await fillCompletedByteCapacity()
        let retained = try XCTUnwrap(completed.first)
        clock.now.addTimeInterval(-ExtensionBridge.responseExpiry * 2)
        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .rejected = await observer.enqueue(
            ingress: try makeFixture(id: 1000, host: "corrected.example").ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected corrected-clock byte-capacity rejection") }
        let retry = try accepted(await observer.enqueue(
            ingress: retained.fixture.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(retry.handle, retained.handle)
        XCTAssertFalse(retry.approvalRequired)
        guard case .found = await observer.load(handle: retained.handle) else {
            return XCTFail("Expected far-future completion retention")
        }
        let profile = try storedProfile()
        let records = try XCTUnwrap(profile["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, completed.count)
    }

    func testCompletedBeforeCreationFailsClosed() async throws {
        let fixture = try makeFixture(id: 64)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let completion = await bridge.completeImmediate(
            handle: handle,
            resolution: immediateResolution(for: fixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        try mutateFirstStoredRecord { record in
            let createdAt = try XCTUnwrap(record["createdAt"] as? Date)
            var state = try XCTUnwrap(record["state"] as? [String: Any])
            var completed = try XCTUnwrap(state["completed"] as? [String: Any])
            completed["since"] = createdAt.addingTimeInterval(-1)
            state["completed"] = completed
            record["state"] = state
        }

        guard case .unavailable = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected impossible chronology to fail closed")
        }
    }

    func testCorruptProfileFailsClosedWithoutBeingOverwritten() async throws {
        let fixture = try makeFixture(id: 70)
        _ = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: defaultProfileURL, options: .atomic)

        guard case .unavailable = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected corrupt profile to be unavailable")
        }
        guard case .unavailable = await bridge.enqueue(
            ingress: try makeFixture(id: 71).ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected fail-closed enqueue") }
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), corrupt)
    }

    func testUnsupportedSchemaFailsWithoutOverwriting()
        async throws {
        _ = try accepted(await bridge.enqueue(
            ingress: makeFixture(id: 730).ingress,
            profileIdentifier: nil
        ))
        var profile = try storedProfile()
        profile["schemaVersion"] = Int.max
        try PropertyListSerialization.data(
            fromPropertyList: profile,
            format: .binary,
            options: 0
        ).write(to: defaultProfileURL, options: .atomic)

        try await assertStoredProfileUnavailableAndUnchanged()
    }

    func testMalformedNativeClaimApprovalIsUnavailableWithoutOverwriting()
        async throws {
        let handle = try accepted(await bridge.enqueue(
            ingress: makeFixture(id: 731, name: "requestAccounts").ingress,
            profileIdentifier: nil
        )).handle
        let delivered = try await recordNativeDelivery(handle: handle)
        XCTAssertEqual(delivered, .persisted)
        guard case .claimed(let claim) = await claimDeliveredNativeExecution(
            in: bridge, handle: handle, approvedAt: clock.now
        ) else { return XCTFail("Expected native claim") }
        defer { claim.releaseUnapproved() }
        let original = try Data(contentsOf: defaultProfileURL)
        let invalidFields: [(String, Any?)] = [
            ("receipt", nil),
            ("approvedAt", nil),
            ("receipt", Data("invalid receipt".utf8)),
            ("approvedAt", clock.now.addingTimeInterval(-1)),
        ]
        for (field, value) in invalidFields {
            try original.write(to: defaultProfileURL, options: .atomic)
            try mutateFirstStoredState("claimed") { claimed in
                var ownership = try XCTUnwrap(claimed["approval"] as? [String: Any])
                var native = try XCTUnwrap(ownership["native"] as? [String: Any])
                var approval = try XCTUnwrap(native["_0"] as? [String: Any])
                approval[field] = value
                native["_0"] = approval
                ownership["native"] = native
                claimed["approval"] = ownership
            }
            try await assertStoredProfileUnavailableAndUnchanged()
        }
    }

    @MainActor
    func testNativeClaimRequiresAValidExecutionContextAfterRestart()
        async throws {
        let execution = try await makeExecutableNativePermit(id: 732)
        defer { execution.permit.releaseLease() }

        let original = try Data(contentsOf: defaultProfileURL)
        let claimed = try firstStoredState("claimed")
        let ownership = try XCTUnwrap(claimed["approval"] as? [String: Any])
        let native = try XCTUnwrap(ownership["native"] as? [String: Any])
        let context = try XCTUnwrap(native["context"] as? [String: Any])
        var beforeApproval = context
        beforeApproval["observedAt"] = clock.now.addingTimeInterval(-1)
        var reversedDeadline = context
        reversedDeadline["executionDeadline"] = clock.now.addingTimeInterval(-1)
        var invalidRevisions = context
        invalidRevisions["revisions"] = ["ethereum": -1, "solana": 0]
        let invalidContexts: [[String: Any]?] = [
            nil, beforeApproval, reversedDeadline, invalidRevisions,
        ]
        for context in invalidContexts {
            try original.write(to: defaultProfileURL, options: .atomic)
            try mutateFirstStoredState("claimed") { claimed in
                var ownership = try XCTUnwrap(claimed["approval"] as? [String: Any])
                var native = try XCTUnwrap(ownership["native"] as? [String: Any])
                native["context"] = context
                ownership["native"] = native
                claimed["approval"] = ownership
            }
            try await assertStoredProfileUnavailableAndUnchanged()
        }
    }

    func testCompletedStateRequiresBooleanAcknowledgementAfterRestart()
        async throws {
        let fixture = try makeFixture(id: 733)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let completion = await bridge.completeImmediate(
            handle: handle,
            resolution: immediateResolution(for: fixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        let original = try Data(contentsOf: defaultProfileURL)
        let invalidAcknowledgements: [Any?] = [nil, "false"]
        for value in invalidAcknowledgements {
            try original.write(to: defaultProfileURL, options: .atomic)
            try mutateFirstStoredState("completed") { completed in
                completed["acknowledged"] = value
            }
            try await assertStoredProfileUnavailableAndUnchanged()
        }
    }

    func testNativeClaimPreservesApprovalTimeAcrossFailedWritesAndRejectsDuplicateExecution()
        async throws {
        let failWrites = LockedTestValue(false)
        bridge = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { data, url in
                if failWrites.value, url.pathExtension == "state" {
                    throw Failure.injectedWrite
                }
                try ApprovalStoreTestPersistence.write(data, url)
            }
        )
        let fixture = try makeFixture(id: 719, name: "requestAccounts")
        let admission = try accepted(await bridge.enqueue(
            ingress: fixture.ingress, profileIdentifier: nil
        ))
        let delivered = try await recordNativeDelivery(handle: admission.handle)
        XCTAssertEqual(delivered, .persisted)
        let approvedAt = clock.now
        failWrites.value = true
        let failed = await claimDeliveredNativeExecution(
            in: bridge, handle: admission.handle, approvedAt: approvedAt
        )
        XCTAssertEqual(failed, .unavailable)
        clock.now.addTimeInterval(60)
        failWrites.value = false
        guard case .claimed(let claim) = await claimDeliveredNativeExecution(
            in: bridge, handle: admission.handle, approvedAt: approvedAt
        ) else { return XCTFail("Expected the delayed native decision") }
        XCTAssertEqual(try nativeApproval(claim).approvedAt, approvedAt)
        XCTAssertEqual(try nativeApproval(claim).context.observedAt, clock.now)
        clock.now.addTimeInterval(10)
        for time in [approvedAt, clock.now] {
            let duplicate = await claimDeliveredNativeExecution(
                in: bridge, handle: admission.handle, approvedAt: time
            )
            XCTAssertEqual(duplicate, .executing)
        }
        let released = await bridge.abandon(claim: claim)
        XCTAssertEqual(released, .persisted)
    }

    func testNativeClaimIsProfileScopedAndReleaseIsTerminal() async throws {
        let profile = UUID()
        let fixture = try makeFixture(id: 720, name: "requestAccounts")
        let handle = try accepted(await bridge.enqueue(
            ingress: try profileFixture(fixture, profileIdentifier: profile).ingress,
            profileIdentifier: profile
        )).handle
        let delivered = try await recordNativeDelivery(handle: handle)
        XCTAssertEqual(delivered, .persisted)
        let approvedAt = clock.now
        clock.now.addTimeInterval(10)
        guard case .found(let snapshot) = await bridge.load(handle: handle) else {
            return XCTFail("Expected delivered snapshot")
        }
        XCTAssertNil(snapshot.nativeApproval)
        XCTAssertNil(snapshot.nativeExecutionContext)
        XCTAssertFalse(snapshot.hasActiveExecution)
        guard case .executing = await bridge.claim(handle: handle) else {
            return XCTFail("Popup claim must not consume native delivery")
        }
        let wrongProfileHandle = ExtensionBridge.Handle(
            id: handle.id, token: handle.token, profileIdentifier: nil
        )
        guard case .missing = await claimDeliveredNativeExecution(
            in: bridge, handle: wrongProfileHandle, approvedAt: approvedAt
        ) else { return XCTFail("Expected profile isolation") }
        guard case .claimed(let nativeClaim) = await claimDeliveredNativeExecution(
            in: bridge, handle: handle, approvedAt: approvedAt
        ) else { return XCTFail("Expected native claim") }
        XCTAssertEqual(try nativeApproval(nativeClaim).approvedAt, approvedAt)
        let releasedClaim = await bridge.abandon(claim: nativeClaim)
        XCTAssertEqual(releasedClaim, .persisted)
        guard case .found(let released) = await bridge.load(handle: handle) else {
            return XCTFail("Expected released snapshot")
        }
        XCTAssertEqual(released.phase, .responded)
        XCTAssertNil(released.nativeApproval)
        let reclaimed = await claimDeliveredNativeExecution(in: bridge, handle: handle, approvedAt: approvedAt)
        XCTAssertEqual(reclaimed, .responded)
    }

    @MainActor
    func testCanceledNativeStoreHopCannotCheckpoint() async throws {
        let execution = try await makeExecutableNativePermit(id: 733)

        _ = execution.permit.recoveryResponse
        let checkpointTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await prepareReviewedBroadcast(execution.permit)
        }
        let checkpoint = await checkpointTask.value
        XCTAssertEqual(checkpoint, .ownershipLost)
        let rollback = await bridge.abandon(permit: execution.permit.permit)
        XCTAssertEqual(rollback, .persisted)
        let received = try responseJSON(await bridge.prepareResponseDelivery(
            id: execution.handle.id, configurationKey: execution.request.configurationKey,
            requestToken: execution.handle.requestToken, profileIdentifier: nil
        ))
        XCTAssertEqual((received["error"] as? [String: Any])?["message"] as? String, Strings.approvalInterrupted)
    }

    func testNativeExecutionRequiresExactReceiptAndValidApprovalTime() async throws {
        let fixture = try makeFixture(id: 734, name: "requestAccounts")
        let admission = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil))
        _ = try await recordNativeDelivery(handle: admission.handle)
        guard case .found(let snapshot) = await bridge.load(handle: admission.handle) else {
            return XCTFail("Expected delivered request")
        }
        let receipt = try XCTUnwrap(snapshot.nativeDeliveryReceipt)
        let approvedAt = clock.now
        let original = try Data(contentsOf: defaultProfileURL)
        for mismatch in ["nonce", "runtime", "future", "past"] {
            let timestamp: Date
            switch mismatch {
            case "future": timestamp = approvedAt.addingTimeInterval(1)
            case "past": timestamp = snapshot.createdAt.addingTimeInterval(-1)
            default: timestamp = approvedAt
            }
            let consent = try await Self.reviewedConsent(
                snapshot, approvedAt: timestamp,
                nativeReceipt: .init(
                    nativeDeliveryNonce: mismatch == "nonce" ? .init(value: UUID()) : receipt.nativeDeliveryNonce,
                    owner: storedRequestNativeOwner(runtime: mismatch == "runtime" ? UUID() : receipt.owner.runtimeInstanceIdentifier)
                )
            )
            let claim = await bridge.claimNativeExecution(consent: consent)
            XCTAssertEqual(claim, .ownershipLost, mismatch)
            XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original, mismatch)
        }
        guard case .claimed(let claimed) = await claimDeliveredNativeExecution(
            in: bridge, handle: admission.handle, approvedAt: approvedAt
        ) else { return XCTFail("Expected exact receipt to claim execution") }
        let fields = try firstStoredNativeApproval("claimed")
        XCTAssertEqual(Set(fields.keys), ["approvedAt", "receipt"])
        let abandoned = await bridge.abandon(claim: claimed)
        XCTAssertEqual(abandoned, .persisted)
        let lateConsent = try await Self.reviewedConsent(snapshot, approvedAt: approvedAt)
        let lateClaim = await bridge.claimNativeExecution(consent: lateConsent)
        XCTAssertEqual(lateClaim, .responded)
        let fresh = try accepted(await bridge.enqueue(ingress: makeFixture(id: 735).ingress, profileIdentifier: nil))
        XCTAssertNotEqual(fresh.handle.token, admission.handle.token)
        guard case .found(let freshSnapshot) = await bridge.load(handle: fresh.handle),
              case .queued(_, .unowned) = freshSnapshot.state else {
            return XCTFail("A new request must start without authorization")
        }
    }

    @MainActor
    func testOrphanedNativeExecutionIsInterruptedWithoutReplay() async throws {
        let execution = try await makeExecutableNativePermit(id: 721)

        execution.permit.releaseLease()
        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        let result = try responseJSON(await observer.prepareResponseDelivery(
            id: execution.handle.id, configurationKey: execution.request.configurationKey,
            requestToken: execution.handle.requestToken, profileIdentifier: nil
        ))
        XCTAssertEqual((result["error"] as? [String: Any])?["message"] as? String, Strings.approvalInterrupted)
        let claimed = await claimDeliveredNativeExecution(in: observer, handle: execution.handle, approvedAt: clock.now)
        XCTAssertEqual(claimed, .responded)
        let lateCompletion = await completeReviewedExecution(execution.permit)
        XCTAssertEqual(lateCompletion, .persisted)
        let unchanged = try responseJSON(await observer.prepareResponseDelivery(
            id: execution.handle.id, configurationKey: execution.request.configurationKey,
            requestToken: execution.handle.requestToken, profileIdentifier: nil
        ))
        XCTAssertEqual((unchanged["error"] as? [String: Any])?["message"] as? String, Strings.approvalInterrupted)
    }

    @MainActor
    func testOrphanedNativeBroadcastPreservesRecoveryResponse() async throws {
        let execution = try await makeExecutableNativePermit(id: 722)

        let recovery = execution.permit.recoveryResponse
        let checkpoint = await prepareReviewedBroadcast(execution.permit)
        XCTAssertEqual(checkpoint, .persisted)
        execution.permit.releaseLease()
        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        let delivered = try responseJSON(await observer.prepareResponseDelivery(
            id: execution.handle.id, configurationKey: execution.request.configurationKey,
            requestToken: execution.handle.requestToken, profileIdentifier: nil
        ))
        XCTAssertEqual(delivered["approvalCommitted"] as? Bool, true)
        XCTAssertEqual(delivered as NSDictionary, recovery.json as NSDictionary)
        XCTAssertEqual((delivered["error"] as? [String: Any])?["code"] as? Int, ProviderResponseError.transactionSubmissionUnknownCode)
    }

    func testClearingNativeDeliveryCannotTransferAnActiveClaim() async throws {
        let fixture = try makeFixture(id: 723, name: "requestAccounts")
        let admission = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil))
        _ = try await recordNativeDelivery(handle: admission.handle)
        guard case .claimed(let claimed) = await claimDeliveredNativeExecution(
            in: bridge, handle: admission.handle, approvedAt: clock.now
        ), case .found(let snapshot) = await bridge.load(handle: admission.handle) else {
            return XCTFail("Expected active native claim")
        }
        defer { claimed.releaseUnapproved() }
        let receipt = try XCTUnwrap(snapshot.nativeDeliveryReceipt)
        let cleared = await bridge.clearNativeDeliveryReceipt(
            handle: admission.handle, nativeDeliveryNonce: receipt.nativeDeliveryNonce,
            runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier
        )
        XCTAssertEqual(cleared, .ownershipLost)
        let competing = await claimDeliveredNativeExecution(
            in: bridge, handle: admission.handle, approvedAt: clock.now
        )
        XCTAssertEqual(competing, .executing)
        let interrupted = await bridge.interruptNativeApproval(
            handle: admission.handle, nativeDeliveryNonce: receipt.nativeDeliveryNonce,
            runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier
        )
        XCTAssertEqual(interrupted, .interrupted)
        let received = try responseJSON(await bridge.prepareResponseDelivery(
            id: admission.handle.id, configurationKey: fixture.request.configurationKey,
            requestToken: admission.handle.requestToken, profileIdentifier: nil
        ))
        XCTAssertEqual((received["error"] as? [String: Any])?["message"] as? String, Strings.approvalInterrupted)
    }

    #if os(macOS)

    func testNativeAgentRouteRoundTripsOnlyTheOpaqueHandle() throws {
        let handle = ExtensionBridge.Handle(
            id: 722,
            token: .init(value: UUID()),
            profileIdentifier: UUID()
        )
        let nativeDeliveryNonce = ExtensionBridge.NativeDeliveryNonce(
            value: UUID()
        )
        let approval = NativeAgentRoute.approval(
            workflowVersion: ExtensionBridge.workflowVersion,
            handle: handle,
            nativeDeliveryNonce: nativeDeliveryNonce
        )
        XCTAssertEqual(NativeAgentRoute(url: approval.url), approval)
        XCTAssertTrue(approval.url.absoluteString.contains(
            "nativeDeliveryNonce=\(nativeDeliveryNonce.rawValue)"
        ))
        XCTAssertFalse(approval.url.absoluteString.contains("signPersonalMessage"))
        XCTAssertEqual(
            NativeAgentRoute(url: NativeAgentRoute.showWallet(
                workflowVersion: ExtensionBridge.workflowVersion
            ).url),
            .showWallet(workflowVersion: ExtensionBridge.workflowVersion)
        )
        var components = try XCTUnwrap(URLComponents(
            url: approval.url,
            resolvingAgainstBaseURL: false
        ))
        components.queryItems?.removeAll(where: {
            $0.name == "nativeDeliveryNonce"
        })
        XCTAssertNil(components.url.flatMap { NativeAgentRoute(url: $0) })
        components = try XCTUnwrap(URLComponents(
            url: approval.url,
            resolvingAgainstBaseURL: false
        ))
        components.queryItems?.append(URLQueryItem(name: "body", value: "forged"))
        XCTAssertNil(components.url.flatMap { NativeAgentRoute(url: $0) })
    }
    #endif

    func testNativeTransactionDecisionRebuildsOnlyMutableExecutionFields() async throws {
        let original = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x1",
            gas: "0x5208",
            value: "0x3",
            data: "0x1234",
            preparedFee: .legacy(gasPrice: 10),
            feeSource: .manual
        )
        var edited = original
        edited.nonce = "0x" + String(repeating: "0", count: 64) + "2"
        edited.gas = "0x" + String(repeating: "0", count: 64) + "6000"
        edited.replacePreparedFee(
            .legacy(gasPrice: 20),
            provenance: .init(gasPrice: .slider)
        )
        let resolvedNetwork = ResolvedEthereumNetwork(
            network: EthereumNetwork(
                chainId: 1,
                name: "Ethereum",
                symbol: "ETH",
                rpcEndpoint: .unauthenticated(
                    URL(string: "https://rpc.example")!
                ),
                isTestnet: false,
                mightShowPrice: true,
                explorer: nil
            ),
            source: .custom
        )
        let account = WalletAccount(
            address: original.from,
            coin: .ethereum,
            derivation: .default,
            derivationPath: "m/44'/60'/0'/0/0",
            publicKey: "",
            extendedPublicKey: ""
        )
        let action = SendTransactionAction(
            transaction: original,
            resolvedNetwork: resolvedNetwork,
            walletId: "wallet",
            account: account
        )
        let execution = try XCTUnwrap(
            DappApprovalDecision.TransactionExecution(
                edited,
                reviewedNetwork: resolvedNetwork,
                approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account)
            )
        )
        let rebuilt = try XCTUnwrap(execution.applying(to: action))
        XCTAssertEqual(rebuilt.from, original.from)
        XCTAssertEqual(rebuilt.to, original.to)
        XCTAssertEqual(rebuilt.value, original.value)
        XCTAssertEqual(rebuilt.data, original.data)
        XCTAssertEqual(rebuilt.accessList, original.accessList)
        XCTAssertEqual(rebuilt.nonce, "0x2")
        XCTAssertEqual(rebuilt.gas, "0x6000")
        XCTAssertEqual(rebuilt.preparedFee, edited.preparedFee)
        XCTAssertEqual(rebuilt.feeProvenance, edited.feeProvenance)

        let changedEndpoint = ResolvedEthereumNetwork(
            network: EthereumNetwork(
                chainId: 1,
                name: "Ethereum",
                symbol: "ETH",
                rpcEndpoint: .unauthenticated(
                    URL(string: "https://other-rpc.example")!
                ),
                isTestnet: false,
                mightShowPrice: true,
                explorer: nil
            ),
            source: .custom
        )
        let changedAction = SendTransactionAction(
            transaction: original,
            resolvedNetwork: changedEndpoint,
            walletId: "wallet",
            account: account
        )
        XCTAssertNil(execution.applying(to: changedAction))

    }

    func testTransactionDecisionPreservesFeeProvenance() throws {
        let network = ResolvedEthereumNetwork(
            network: EthereumNetwork(
                chainId: 1,
                name: "Ethereum",
                symbol: "ETH",
                rpcEndpoint: .unauthenticated(URL(string: "https://rpc.example")!),
                isTestnet: false,
                mightShowPrice: true,
                explorer: nil
            ),
            source: .custom
        )
        let legacy = PreparedTransactionFee.legacy(gasPrice: 10)
        let eip1559 = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: 2,
            maxFeePerGas: 10
        )
        let sources: [TransactionFeeSource] = [.automatic, .dapp, .slider, .manual]
        var cases: [(PreparedTransactionFee, TransactionFeeProvenance)] = [
            (legacy, .init()),
            (eip1559, .init()),
            (eip1559, .init(maxPriorityFeePerGas: .dapp, maxFeePerGas: .manual)),
        ]
        for source in sources {
            cases.append((legacy, .init(gasPrice: source)))
            cases.append((eip1559, .init(maxPriorityFeePerGas: source, maxFeePerGas: source)))
        }

        for (fee, provenance) in cases {
            let transaction = Transaction(
                from: "0x0000000000000000000000000000000000000001",
                to: "0x0000000000000000000000000000000000000002",
                nonce: "0x1",
                gas: "0x5208",
                value: "0x0",
                data: "0x",
                preparedFee: fee,
                feeProvenance: provenance
            )
            let action = SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: network,
                walletId: "wallet",
                account: WalletAccount(
                    address: transaction.from,
                    coin: .ethereum,
                    derivation: .default,
                    derivationPath: "m/44'/60'/0'/0/0",
                    publicKey: "",
                    extendedPublicKey: ""
                )
            )
            let execution = try XCTUnwrap(DappApprovalDecision.TransactionExecution(
                transaction,
                reviewedNetwork: network,
                approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account)
            ))
            let rebuilt = try XCTUnwrap(execution.applying(to: action))
            XCTAssertEqual(rebuilt.preparedFee, fee)
            XCTAssertEqual(rebuilt.feeProvenance, provenance)
        }
    }

    #if os(macOS)
    func testExpectedRuntimeRefreshesAfterBundleReplacement() throws {
        let bundleURL = try makeAmbientBundle(name: "Installed", build: "148")
        let previous = try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: bundleURL))
        XCTAssertTrue(previous.installedVersionMatches)

        let replacementURL = try makeAmbientBundle(name: "Replacement", build: "149")
        try FileManager.default.removeItem(at: bundleURL)
        try FileManager.default.moveItem(at: replacementURL, to: bundleURL)

        XCTAssertFalse(previous.installedVersionMatches)
        let current = try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: bundleURL))
        XCTAssertEqual(current.version, .init(marketing: "1.0.99", build: "149"))
        XCTAssertTrue(current.installedVersionMatches)
    }

    @MainActor
    func testCurrentRuntimeIdentityRoundTripsItsWorkflowAndInstalledVersion() throws {
        let bundleURL = try makeAmbientBundle(name: "Current", build: "148")
        let identity = try XCTUnwrap(AmbientRuntimeIdentity.current(
            bundle: try XCTUnwrap(Bundle(url: bundleURL)),
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            launchedAt: Date(timeIntervalSince1970: 9_001)
        ))
        XCTAssertEqual(identity.workflowVersion, ExtensionBridge.workflowVersion)
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")
        XCTAssertTrue(identity.persistForCurrentProcess(directoryURL: directoryURL))
        XCTAssertEqual(AmbientRuntimeIdentity.load(
            processIdentifier: identity.processIdentifier, directoryURL: directoryURL
        ), identity)
        XCTAssertTrue(identity.isCompatible(
            withWorkflowVersion: ExtensionBridge.workflowVersion, expectedVersion: identity.version
        ))
    }

    func testRuntimeIdentityRejectsMalformedWorkflowVersions() throws {
        let bundleURL = try makeAmbientBundle(name: "Invalid", build: "148")
        let identity = try runtimeIdentity(
            processIdentifier: 792, bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_001)
        )
        let original = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(identity)
        ) as? [String: Any])
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let invalidValues: [Any?] = [nil, 0, -1, "4", NSNull(), true, 1.5]
        for value in invalidValues {
            var json = original
            json["workflowVersion"] = value
            try JSONSerialization.data(withJSONObject: json).write(
                to: directoryURL.appendingPathComponent("792.json"), options: .atomic
            )
            XCTAssertNil(AmbientRuntimeIdentity.load(
                processIdentifier: identity.processIdentifier, directoryURL: directoryURL
            ))
        }
    }

    func testRuntimeIdentityLoadsMismatchedWorkflowForRejection() throws {
        let bundleURL = try makeAmbientBundle(name: "Protocol", build: "148")
        let identity = try runtimeIdentity(
            processIdentifier: 791,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 1_789_118_464.514548),
            workflowVersion:
                ExtensionBridge.workflowVersion + 1
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(identity).write(
            to: directoryURL.appendingPathComponent("791.json"),
            options: .atomic
        )
        XCTAssertEqual(
            AmbientRuntimeIdentity.load(
                processIdentifier: identity.processIdentifier,
                directoryURL: directoryURL
            ),
            identity
        )
        XCTAssertFalse(identity.isCompatible(
            withWorkflowVersion: ExtensionBridge.workflowVersion, expectedVersion: identity.version
        ))
    }

    @MainActor
    func testRuntimeIdentityPersistenceReportsWriteFailure() throws {
        let bundleURL = try makeAmbientBundle(name: "Persist", build: "148")
        let identity = try runtimeIdentity(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_001)
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")

        try Data("occupied".utf8).write(to: directoryURL)
        XCTAssertFalse(identity.persistForCurrentProcess(directoryURL: directoryURL))
        XCTAssertNil(AmbientRuntimeIdentity.load(
            processIdentifier: identity.processIdentifier,
            directoryURL: directoryURL
        ))
        try FileManager.default.removeItem(at: directoryURL)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o500]
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        }
        XCTAssertFalse(identity.persistForCurrentProcess(directoryURL: directoryURL))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        XCTAssertTrue(identity.persistForCurrentProcess(directoryURL: directoryURL))
        XCTAssertEqual(AmbientRuntimeIdentity.load(
            processIdentifier: identity.processIdentifier,
            directoryURL: directoryURL
        ), identity)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directoryURL.path),
            ["\(identity.processIdentifier).json"]
        )
    }

    @MainActor
    func testRuntimeIdentityClearReportsRemovalFailureAndRetries() throws {
        let bundleURL = try makeAmbientBundle(name: "Clear", build: "148")
        let identity = try runtimeIdentity(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_002)
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")
        XCTAssertTrue(identity.persistForCurrentProcess(directoryURL: directoryURL))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directoryURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        }
        XCTAssertFalse(identity.clearForCurrentProcess(directoryURL: directoryURL))
        XCTAssertEqual(AmbientRuntimeIdentity.load(
            processIdentifier: identity.processIdentifier,
            directoryURL: directoryURL
        ), identity)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        XCTAssertTrue(identity.clearForCurrentProcess(directoryURL: directoryURL))
        XCTAssertTrue(identity.clearForCurrentProcess(directoryURL: directoryURL))
        XCTAssertNil(AmbientRuntimeIdentity.load(
            processIdentifier: identity.processIdentifier,
            directoryURL: directoryURL
        ))
    }

    @MainActor
    func testRuntimeIdentityClearPreservesReplacementInstance() throws {
        let bundleURL = try makeAmbientBundle(name: "Replaced", build: "148")
        let original = try runtimeIdentity(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_003)
        )
        let replacement = try runtimeIdentity(
            processIdentifier: original.processIdentifier,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_004)
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")
        XCTAssertTrue(original.persistForCurrentProcess(directoryURL: directoryURL))
        XCTAssertEqual(AmbientRuntimeIdentity.load(
            processIdentifier: original.processIdentifier,
            directoryURL: directoryURL
        ), original)
        XCTAssertTrue(replacement.persistForCurrentProcess(directoryURL: directoryURL))

        XCTAssertFalse(original.clearForCurrentProcess(directoryURL: directoryURL))
        XCTAssertEqual(AmbientRuntimeIdentity.load(
            processIdentifier: original.processIdentifier,
            directoryURL: directoryURL
        ), replacement)
        XCTAssertTrue(replacement.clearForCurrentProcess(directoryURL: directoryURL))
    }

    @MainActor
    func testRuntimeIdentityMutationsRejectAnotherProcess() throws {
        let bundleURL = try makeAmbientBundle(name: "Foreign", build: "148")
        let processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier == 1 ? 2 : 1
        let identity = try runtimeIdentity(
            processIdentifier: processIdentifier,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_004)
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")
        XCTAssertFalse(identity.persistForCurrentProcess(directoryURL: directoryURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryURL.path))
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(identity).write(
            to: directoryURL.appendingPathComponent("\(processIdentifier).json"),
            options: .atomic
        )
        XCTAssertFalse(identity.clearForCurrentProcess(directoryURL: directoryURL))
        XCTAssertEqual(AmbientRuntimeIdentity.load(
            processIdentifier: processIdentifier,
            directoryURL: directoryURL
        ), identity)
    }

    @MainActor
    func testRuntimeIdentityClearDoesNotCreateMissingDirectory() throws {
        let bundleURL = try makeAmbientBundle(name: "Missing", build: "148")
        let identity = try runtimeIdentity(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_004)
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")
        XCTAssertTrue(identity.clearForCurrentProcess(directoryURL: directoryURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryURL.path))
    }

    func testRuntimeIdentityRejectsMalformedAndMismatchedFiles() throws {
        let bundleURL = try makeAmbientBundle(name: "Invalid", build: "148")
        let identity = try runtimeIdentity(
            processIdentifier: 795,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_005)
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = directoryURL.appendingPathComponent("795.json")
        let data = try JSONEncoder().encode(identity)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["processIdentifier"] = 796
        let wrongPID = try JSONSerialization.data(withJSONObject: object)
        object["processIdentifier"] = 795
        object["bundlePath"] = "/not-an-app"
        let invalidIdentity = try JSONSerialization.data(withJSONObject: object)

        for invalid in [
            Data(), Data("{".utf8), Data(repeating: 0x20, count: 4_097),
            wrongPID, invalidIdentity,
        ] {
            try invalid.write(to: fileURL, options: .atomic)
            XCTAssertNil(AmbientRuntimeIdentity.load(
                processIdentifier: identity.processIdentifier,
                directoryURL: directoryURL
            ))
        }
        XCTAssertNil(AmbientRuntimeIdentity.load(
            processIdentifier: 0,
            directoryURL: directoryURL
        ))
    }

    func testRuntimeIdentityRejectsUnreadableOrUnsafeFiles() throws {
        let bundleURL = try makeAmbientBundle(name: "Unreadable", build: "148")
        let identity = try runtimeIdentity(
            processIdentifier: 796,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_006)
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = directoryURL.appendingPathComponent("796.json")
        try JSONEncoder().encode(identity).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: fileURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
        XCTAssertNil(AmbientRuntimeIdentity.load(
            processIdentifier: identity.processIdentifier,
            directoryURL: directoryURL
        ))
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createSymbolicLink(
            at: fileURL,
            withDestinationURL: directoryURL.appendingPathComponent("missing")
        )
        XCTAssertNil(AmbientRuntimeIdentity.load(
            processIdentifier: identity.processIdentifier,
            directoryURL: directoryURL
        ))
    }

    func testRuntimeIdentityReturnsNilForMissingFile() throws {
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")
        XCTAssertNil(AmbientRuntimeIdentity.load(
            processIdentifier: 797,
            directoryURL: directoryURL
        ))
    }

    @MainActor
    func testNativeAgentResolutionDoesNotVerifyBeforeAProcessAction() async throws {
        let currentURL = try makeAmbientBundle(name: "Unlaunched", build: "149")
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in
                    XCTFail("Selecting a candidate must leave verification to launch")
                    return false
                },
                helpers: { [] },
                identity: { _ in nil }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        XCTAssertEqual(
            selected,
            .launch(url: currentURL))
    }

    @MainActor
    func testNativeAgentUnknownRuntimePollsVerifyOnlyBeforeQuit() async throws {
        let currentURL = try makeAmbientBundle(name: "Starting", build: "149")
        let uptime = LockedTestValue<UInt64>(0)
        let isRunning = LockedTestValue(true)
        let verifications = LockedTestValue(0)
        let quitCount = LockedTestValue(0)
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in
                    XCTAssertGreaterThanOrEqual(uptime.value, 1_000_000_000)
                    verifications.withValue { $0 += 1 }
                    return true
                },
                helpers: {
                    isRunning.value
                        ? [
                            self.runtimeHelper(
                                processIdentifier: 798,
                                bundleURL: currentURL,
                                launchDate: Date(timeIntervalSince1970: 9_000),
                                isRunning: { isRunning.value },
                                requestQuit: {
                                    XCTAssertEqual(verifications.value, 1)
                                    quitCount.withValue { $0 += 1 }
                                    isRunning.value = false
                                    return true
                                }
                            )
                        ] : []
                },
                identity: { _ in nil },
                uptime: { uptime.value },
                sleepUntil: { deadline in uptime.withValue { $0 = max($0, deadline) } }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        XCTAssertEqual(
            selected,
            .launch(url: currentURL))
        XCTAssertEqual(verifications.value, 1)
        XCTAssertEqual(quitCount.value, 1)
    }

    @MainActor
    func testNativeAgentResolutionRevalidatesRetirementAfterSuspension() async throws {
        let currentURL = try makeAmbientBundle(name: "Retirement Passes", build: "149")
        let launchDate = Date(timeIntervalSince1970: 9_500)
        let processIdentifiers: [Int32] = [861, 862, 863, 864]
        let identities = try Dictionary(
            uniqueKeysWithValues: processIdentifiers.map {
                (
                    $0,
                    try runtimeIdentity(
                        processIdentifier: $0,
                        bundleURL: currentURL,
                        launchDate: launchDate,
                        workflowVersion: ExtensionBridge.workflowVersion + 1
                    )
                )
            })
        let pass = LockedTestValue(0)
        let verifiedPasses = LockedTestValue([Int]())
        var retiredProcesses = [Int32]()
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { url in
                    XCTAssertEqual(url, currentURL)
                    verifiedPasses.withValue { $0.append(pass.value) }
                    return true
                },
                helpers: {
                    guard pass.value < 2 else { return [] }
                    return processIdentifiers[(pass.value * 2)..<(pass.value * 2 + 2)].map { processIdentifier in
                        self.runtimeHelper(
                            processIdentifier: processIdentifier,
                            bundleURL: currentURL,
                            launchDate: launchDate,
                            requestQuit: {
                                XCTAssertEqual(verifiedPasses.value, Array(0...pass.value))
                                retiredProcesses.append(processIdentifier)
                                return true
                            }
                        )
                    }
                },
                identity: { identities[$0] },
                sleepUntil: { _ in pass.withValue { $0 += 1 } }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        XCTAssertEqual(
            selected,
            .launch(url: currentURL))
        XCTAssertEqual(verifiedPasses.value, [0, 1])
        XCTAssertEqual(retiredProcesses, processIdentifiers)
    }

    @MainActor
    func testNativeAgentResolutionIgnoresOtherPaths() async throws {
        let currentURL = try makeAmbientBundle(name: "Current", build: "148")
        let otherURL = try makeAmbientBundle(name: "Other", build: "149")
        let launchDate = Date(timeIntervalSince1970: 10_000)
        let identities = [
            Int32(801): try runtimeIdentity(
                processIdentifier: 801,
                bundleURL: currentURL,
                launchDate: launchDate
            ),
            Int32(802): try runtimeIdentity(
                processIdentifier: 802,
                bundleURL: otherURL,
                launchDate: launchDate
            ),
        ]
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { $0 == currentURL },
                helpers: {
                    [
                        self.runtimeHelper(
                            processIdentifier: 801,
                            bundleURL: currentURL,
                            launchDate: launchDate
                        ),
                        self.runtimeHelper(
                            processIdentifier: 802,
                            bundleURL: otherURL,
                            launchDate: launchDate
                        ),
                    ]
                },
                identity: { identities[$0] }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        guard let selected,
            case .running(
                let selectedURL,
                let processIdentifier,
                let runtimeInstanceIdentifier
            ) = selected
        else { return XCTFail("Expected running target") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertEqual(processIdentifier, 801)
        XCTAssertEqual(
            runtimeInstanceIdentifier,
            identities[801]?.instanceIdentifier
        )
    }

    @MainActor
    func testNativeAgentResolutionFailsClosedWhenUnknownRetirementIsRefused()
        async throws
    {
        let currentURL = try makeAmbientBundle(name: "Unknown", build: "148")
        let uptime = LockedTestValue<UInt64>(0)
        let quitCount = LockedTestValue(0)
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    [
                        self.runtimeHelper(
                            processIdentifier: 811,
                            bundleURL: currentURL,
                            launchDate: Date(timeIntervalSince1970: 11_000),
                            requestQuit: {
                                quitCount.withValue { $0 += 1 }
                                return false
                            }
                        )
                    ]
                },
                identity: { _ in nil },
                uptime: { uptime.value },
                sleepUntil: { deadline in uptime.withValue { $0 = max($0, deadline) } }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        XCTAssertNil(selected)
        XCTAssertEqual(quitCount.value, 1)
    }

    @MainActor
    func testNativeAgentResolutionLaunchesAfterLegacyRuntimeExits() async throws {
        let currentURL = try makeAmbientBundle(name: "Legacy", build: "149")
        let launchDate = Date(timeIntervalSince1970: 11_500)
        let uptime = LockedTestValue<UInt64>(0)
        let isLegacyRunning = LockedTestValue(true)
        let requestCount = LockedTestValue(0)
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    guard isLegacyRunning.value else { return [] }
                    return [
                        self.runtimeHelper(
                            processIdentifier: 812,
                            bundleURL: currentURL,
                            launchDate: launchDate,
                            isRunning: { isLegacyRunning.value },
                            requestQuit: {
                                requestCount.withValue { $0 += 1 }
                                isLegacyRunning.value = false
                                return true
                            }
                        )
                    ]
                },
                identity: { _ in nil },
                uptime: { uptime.value },
                sleepUntil: { deadline in uptime.withValue { $0 = max($0, deadline) } }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        guard let selected,
            case .launch(let selectedURL) = selected
        else { return XCTFail("Expected fresh helper launch") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertEqual(requestCount.value, 1)
    }

    @MainActor
    func testNativeAgentResolutionAllowsNewRuntimeToPublishIdentity() async throws {
        let currentURL = try makeAmbientBundle(name: "Starting", build: "149")
        let launchDate = Date(timeIntervalSince1970: 11_600)
        let identity = try runtimeIdentity(
            processIdentifier: 813,
            bundleURL: currentURL,
            launchDate: launchDate
        )
        let uptime = LockedTestValue<UInt64>(0)
        var publishedIdentity: AmbientRuntimeIdentity?
        let isRunning = LockedTestValue(true)
        let identityReadCount = LockedTestValue(0)
        let quitCount = LockedTestValue(0)
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    guard isRunning.value else { return [] }
                    return [
                        self.runtimeHelper(
                            processIdentifier: 813,
                            bundleURL: currentURL,
                            launchDate: launchDate,
                            requestQuit: {
                                quitCount.withValue { $0 += 1 }
                                isRunning.value = false
                                return true
                            }
                        )
                    ]
                },
                identity: { _ in
                    identityReadCount.withValue { $0 += 1 }
                    if uptime.value >= 350_000_000 {
                        publishedIdentity = identity
                    }
                    return publishedIdentity
                },
                uptime: { uptime.value },
                sleepUntil: { deadline in uptime.withValue { $0 = max($0, deadline) } }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        guard let selected,
            case .running(
                let selectedURL,
                let processIdentifier,
                let instanceIdentifier
            ) = selected
        else { return XCTFail("Expected running helper target") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertEqual(processIdentifier, identity.processIdentifier)
        XCTAssertEqual(instanceIdentifier, identity.instanceIdentifier)
        XCTAssertGreaterThan(identityReadCount.value, 5)
        XCTAssertEqual(quitCount.value, 0)
    }

    @MainActor
    func testNativeAgentResolutionRechecksIdentityBeforeUnknownRetirement()
        async throws
    {
        let currentURL = try makeAmbientBundle(name: "Boundary", build: "149")
        let launchDate = Date(timeIntervalSince1970: 11_650)
        let identity = try runtimeIdentity(
            processIdentifier: 817,
            bundleURL: currentURL,
            launchDate: launchDate
        )
        let uptime = LockedTestValue<UInt64>(0)
        let boundaryReadCount = LockedTestValue(0)
        let quitCount = LockedTestValue(0)
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    [
                        self.runtimeHelper(
                            processIdentifier: 817,
                            bundleURL: currentURL,
                            launchDate: launchDate,
                            requestQuit: {
                                quitCount.withValue { $0 += 1 }
                                return true
                            }
                        )
                    ]
                },
                identity: { _ in
                    guard uptime.value >= 1_000_000_000 else { return nil }
                    boundaryReadCount.withValue { $0 += 1 }
                    return boundaryReadCount.value > 1 ? identity : nil
                },
                uptime: { uptime.value },
                sleepUntil: { deadline in uptime.withValue { $0 = max($0, deadline) } }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        guard let selected,
            case .running(
                _,
                let processIdentifier,
                let instanceIdentifier
            ) = selected
        else { return XCTFail("Expected running helper target") }
        XCTAssertEqual(processIdentifier, identity.processIdentifier)
        XCTAssertEqual(instanceIdentifier, identity.instanceIdentifier)
        XCTAssertEqual(boundaryReadCount.value, 2)
        XCTAssertEqual(quitCount.value, 0)
    }

    @MainActor
    func testNativeAgentResolutionPreservesUnknownOtherPath() async throws {
        let currentURL = try makeAmbientBundle(name: "Current", build: "149")
        let otherURL = try makeAmbientBundle(name: "Other Legacy", build: "148")
        let quitCount = LockedTestValue(0)
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    [
                        self.runtimeHelper(
                            processIdentifier: 814,
                            bundleURL: otherURL,
                            launchDate: Date(timeIntervalSince1970: 11_700),
                            requestQuit: {
                                quitCount.withValue { $0 += 1 }
                                return true
                            }
                        )
                    ]
                },
                identity: { _ in nil }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        guard let selected,
            case .launch(let selectedURL) = selected
        else { return XCTFail("Expected fresh helper launch") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertEqual(quitCount.value, 0)
    }

    @MainActor
    func testUnknownSamePathRetirementPreservesUnknownOtherPath()
        async throws
    {
        let currentURL = try makeAmbientBundle(name: "Current", build: "149")
        let otherURL = try makeAmbientBundle(name: "Other Legacy", build: "148")
        let launchDate = Date(timeIntervalSince1970: 11_800)
        let uptime = LockedTestValue<UInt64>(0)
        let samePathIsRunning = LockedTestValue(true)
        let samePathQuitCount = LockedTestValue(0)
        let otherPathQuitCount = LockedTestValue(0)
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    var result = [
                        self.runtimeHelper(
                            processIdentifier: 815,
                            bundleURL: otherURL,
                            launchDate: launchDate,
                            requestQuit: {
                                otherPathQuitCount.withValue { $0 += 1 }
                                return true
                            }
                        )
                    ]
                    if samePathIsRunning.value {
                        result.append(
                            self.runtimeHelper(
                                processIdentifier: 816,
                                bundleURL: currentURL,
                                launchDate: launchDate,
                                isRunning: { samePathIsRunning.value },
                                requestQuit: {
                                    samePathQuitCount.withValue { $0 += 1 }
                                    samePathIsRunning.value = false
                                    return true
                                }
                            ))
                    }
                    return result
                },
                identity: { _ in nil },
                uptime: { uptime.value },
                sleepUntil: { deadline in uptime.withValue { $0 = max($0, deadline) } }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        guard let selected,
            case .launch(let selectedURL) = selected
        else { return XCTFail("Expected fresh helper launch") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertEqual(samePathQuitCount.value, 1)
        XCTAssertEqual(otherPathQuitCount.value, 0)
    }

    @MainActor
    func testNativeAgentResolutionRetiresIncompatibleRuntimeBeforeLaunch() async throws {
        let currentURL = try makeAmbientBundle(name: "Incompatible", build: "148")
        let launchDate = Date(timeIntervalSince1970: 12_000)
        let identity = try runtimeIdentity(
            processIdentifier: 821,
            bundleURL: currentURL,
            launchDate: launchDate,
            workflowVersion: ExtensionBridge.workflowVersion + 1
        )
        let isRunning = LockedTestValue(true)
        let quitCount = LockedTestValue(0)
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    guard isRunning.value else { return [] }
                    return [
                        self.runtimeHelper(
                            processIdentifier: 821,
                            bundleURL: currentURL,
                            launchDate: launchDate,
                            isRunning: { isRunning.value },
                            requestQuit: {
                                quitCount.withValue { $0 += 1 }
                                return true
                            }
                        )
                    ]
                },
                identity: { _ in identity },
                sleepUntil: { _ in isRunning.value = false }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        guard let selected,
            case .launch(let selectedURL) = selected
        else { return XCTFail("Expected launch target") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertEqual(quitCount.value, 1)
    }

    @MainActor
    func testNativeAgentResolutionTargetsCompatibleSamePathRuntime() async throws {
        let currentURL = try makeAmbientBundle(name: "Mixed", build: "148")
        let launchDate = Date(timeIntervalSince1970: 13_000)
        let compatible = try runtimeIdentity(
            processIdentifier: 831,
            bundleURL: currentURL,
            launchDate: launchDate
        )
        let incompatible = try runtimeIdentity(
            processIdentifier: 832,
            bundleURL: currentURL,
            launchDate: launchDate,
            workflowVersion: ExtensionBridge.workflowVersion + 1
        )
        let incompatibleIsRunning = LockedTestValue(true)
        let quitCount = LockedTestValue(0)
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    var result = [
                        self.runtimeHelper(
                            processIdentifier: 831,
                            bundleURL: currentURL,
                            launchDate: launchDate
                        )
                    ]
                    if incompatibleIsRunning.value {
                        result.append(
                            self.runtimeHelper(
                                processIdentifier: 832,
                                bundleURL: currentURL,
                                launchDate: launchDate,
                                isRunning: { incompatibleIsRunning.value },
                                requestQuit: {
                                    quitCount.withValue { $0 += 1 }
                                    return true
                                }
                            ))
                    }
                    return result
                },
                identity: { processIdentifier in
                    processIdentifier == 831 ? compatible : incompatible
                },
                sleepUntil: { _ in incompatibleIsRunning.value = false }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        guard let selected,
            case .running(
                let selectedURL,
                let processIdentifier,
                let runtimeInstanceIdentifier
            ) = selected
        else { return XCTFail("Expected running target") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertEqual(processIdentifier, 831)
        XCTAssertEqual(
            runtimeInstanceIdentifier,
            compatible.instanceIdentifier
        )
        XCTAssertEqual(quitCount.value, 1)
    }

    @MainActor
    func testNativeAgentResolutionRejectsOldBuildAtCurrentPath() async throws {
        let currentURL = try makeAmbientBundle(name: "Current", build: "149")
        let oldURL = try makeAmbientBundle(name: "Old", build: "148")
        let launchDate = Date(timeIntervalSince1970: 13_500)
        let identity = AmbientRuntimeIdentity(
            instanceIdentifier: UUID(),
            processIdentifier: 833,
            bundlePath: currentURL.standardizedFileURL.path,
            version: try XCTUnwrap(
                AmbientRuntimeIdentity.bundleVersion(at: oldURL)
            ),
            workflowVersion: ExtensionBridge.workflowVersion,
            launchedAt: launchDate
        )
        let isRunning = LockedTestValue(true)
        let quitCount = LockedTestValue(0)

        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    guard isRunning.value else { return [] }
                    return [
                        self.runtimeHelper(
                            processIdentifier: 833,
                            bundleURL: currentURL,
                            launchDate: launchDate,
                            isRunning: { isRunning.value },
                            requestQuit: {
                                quitCount.withValue { $0 += 1 }
                                return true
                            }
                        )
                    ]
                },
                identity: { _ in identity },
                sleepUntil: { _ in isRunning.value = false }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        guard let selected,
            case .launch(let selectedURL) = selected
        else { return XCTFail("Expected a fresh helper launch") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertEqual(quitCount.value, 1)
    }

    @MainActor
    func testNativeAgentResolutionFailsClosedWhenRetirementIsRefused()
        async throws
    {
        let currentURL = try makeAmbientBundle(name: "Refuses Quit", build: "149")
        let launchDate = Date(timeIntervalSince1970: 13_550)
        let identity = try runtimeIdentity(
            processIdentifier: 835,
            bundleURL: currentURL,
            launchDate: launchDate,
            workflowVersion: ExtensionBridge.workflowVersion + 1
        )
        let quitCount = LockedTestValue(0)

        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    [
                        self.runtimeHelper(
                            processIdentifier: 835,
                            bundleURL: currentURL,
                            launchDate: launchDate,
                            requestQuit: {
                                quitCount.withValue { $0 += 1 }
                                return false
                            }
                        )
                    ]
                },
                identity: { _ in identity }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        XCTAssertNil(selected)
        XCTAssertEqual(quitCount.value, 1)
    }

    func testNativeAgentCompatibilityRejectsReceiptOwnerAtOtherPath()
        throws {
        let expectedURL = try makeAmbientBundle(name: "Expected", build: "149")
        let otherURL = try makeAmbientBundle(name: "Other", build: "149")
        let identity = try runtimeIdentity(
            processIdentifier: 834,
            bundleURL: otherURL,
            launchDate: Date(timeIntervalSince1970: 13_600)
        )

        XCTAssertFalse(try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: expectedURL)).isCompatible(
            identity, runtimeURL: otherURL
        ))
        XCTAssertTrue(try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: otherURL)).isCompatible(
            identity, runtimeURL: otherURL
        ))
    }

    @MainActor
    func testReceiptObservationUsesExactProcessIdentity() async throws {
        let url = try makeAmbientBundle(name: "Receipt Identity", build: "149")
        let original = try runtimeIdentity(
            processIdentifier: 844, bundleURL: url,
            launchDate: Date(timeIntervalSince1970: 14_000)
        )
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: .init(value: UUID()),
            owner: try XCTUnwrap(original.nativeDeliveryOwner)
        )
        for scenario in ["missing", "terminated", "reused", "unreadableStart", "unreadableIdentity", "differentIdentity"] {
            var lookups = [Int32]()
            let status = NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in XCTFail("Unconfirmed owners must not verify signatures"); return false },
                helper: { pid in
                    lookups.append(pid)
                    guard scenario != "missing" else { return nil }
                    return NativeAgentLauncher.RuntimeHelper(
                        processIdentifier: pid,
                        bundleURL: url,
                        processStartDate: scenario == "unreadableStart" ? nil : original.launchedAt.addingTimeInterval(scenario == "reused" ? 1 : 0),
                        isRunning: { scenario != "terminated" },
                        requestQuit: { XCTFail("Unverified owners must not be quit"); return false }
                    )
                },
                identity: { _ in
                    if scenario == "unreadableIdentity" { return nil }
                    return AmbientRuntimeIdentity(
                        instanceIdentifier: scenario == "differentIdentity" ? UUID() : original.instanceIdentifier,
                        processIdentifier: original.processIdentifier,
                        bundlePath: original.bundlePath,
                        version: original.version,
                        workflowVersion: original.workflowVersion,
                        launchedAt: original.launchedAt
                    )
                }
            )).observe(
                owner: receipt.owner,
                expected: .init(url: url, version: original.version)
            )
            XCTAssertEqual(lookups, [original.processIdentifier])
            if ["missing", "terminated", "reused"].contains(scenario) {
                guard case .absent = status else { XCTFail("Expected absent: \(scenario)"); continue }
            } else {
                guard case .unidentified = status else { XCTFail("Expected indeterminate: \(scenario)"); continue }
            }
        }
    }

    @MainActor
    func testCompatibleRuntimeObservationsNeverVerifyCode() throws {
        let bundleURL = try makeAmbientBundle(name: "Observed Runtime", build: "149")
        let identity = try runtimeIdentity(
            processIdentifier: 845,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 14_100)
        )
        let helper = runtimeHelper(
            processIdentifier: identity.processIdentifier,
            bundleURL: bundleURL,
            launchDate: identity.launchedAt
        )
        let launcher = NativeAgentLauncher(dependencies: launcherTestDependencies(
            helperURL: { bundleURL },
            validate: { _ in
                XCTFail("Observation must not verify code")
                return false
            },
            helpers: { [helper] },
            helper: { _ in helper },
            identity: { _ in identity }
        ))
        let owner = try XCTUnwrap(identity.nativeDeliveryOwner)
        let expected = try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: bundleURL))

        for _ in 0..<3 {
            guard case .compatible(let observed) = launcher.observe(owner: owner) else {
                return XCTFail("Expected compatible receipt owner")
            }
            XCTAssertEqual(observed.identity, identity)
            XCTAssertTrue(launcher.isConfirmed(expected, deadline: UInt64.max))
        }
    }

    @MainActor
    func testRuntimeObservationRechecksIdentityBeforeReportingCompatibility() throws {
        let bundleURL = try makeAmbientBundle(name: "Changing Observed Runtime", build: "149")
        let original = try runtimeIdentity(
            processIdentifier: 849,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 14_100)
        )
        let replacement = try runtimeIdentity(
            processIdentifier: original.processIdentifier,
            bundleURL: bundleURL,
            launchDate: original.launchedAt
        )
        let helper = runtimeHelper(
            processIdentifier: original.processIdentifier,
            bundleURL: bundleURL,
            launchDate: original.launchedAt
        )
        let owner = try XCTUnwrap(original.nativeDeliveryOwner)
        let expected = try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: bundleURL))

        for confirm in [false, true] {
            let identityReads = LockedTestValue(0)
            let launcher = NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in
                    XCTFail("Observation must not verify code")
                    return false
                },
                helpers: { [helper] },
                helper: { _ in helper },
                identity: { _ in
                    identityReads.withValue { $0 += 1 }
                    return identityReads.value == 1 ? original : replacement
                }
            ))

            if confirm {
                XCTAssertFalse(launcher.isConfirmed(expected, deadline: UInt64.max))
            } else {
                guard case .unidentified = launcher.observe(owner: owner, expected: expected) else {
                    return XCTFail("A changed runtime must not retain ownership")
                }
            }
            XCTAssertEqual(identityReads.value, 2)
        }
    }

    @MainActor
    func testRuntimeConfirmationStopsAtDeadlineDuringObservation() throws {
        let bundleURL = try makeAmbientBundle(name: "Confirmation Deadline", build: "149")
        let identity = try runtimeIdentity(
            processIdentifier: 850,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 14_100)
        )
        let helper = runtimeHelper(
            processIdentifier: identity.processIdentifier,
            bundleURL: bundleURL,
            launchDate: identity.launchedAt
        )
        let uptime = LockedTestValue<UInt64>(0)
        let launcher = NativeAgentLauncher(dependencies: launcherTestDependencies(
            validate: { _ in
                XCTFail("Observation must not verify code")
                return false
            },
            helpers: { [helper] },
            identity: { _ in
                uptime.value = 50_000_000
                return identity
            },
            uptime: { uptime.value }
        ))

        XCTAssertFalse(launcher.isConfirmed(
            try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: bundleURL)),
            deadline: 50_000_000
        ))
    }

    @MainActor
    func testRuntimeRetirementVerificationRechecksIdentityAfterCodeVerification() async throws {
        let bundleURL = try makeAmbientBundle(name: "Replaced During Verification", build: "149")
        let launchDate = Date(timeIntervalSince1970: 14_100)
        let original = try runtimeIdentity(
            processIdentifier: 845,
            bundleURL: bundleURL,
            launchDate: launchDate
        )
        let replacement = try runtimeIdentity(
            processIdentifier: 845,
            bundleURL: bundleURL,
            launchDate: launchDate
        )
        let helper = runtimeHelper(
            processIdentifier: 845,
            bundleURL: bundleURL,
            launchDate: launchDate
        )
        var identity = original
        let verifications = LockedTestValue(0)
        let verified = await NativeAgentLauncher(dependencies: launcherTestDependencies(
            helperURL: { bundleURL },
            validate: { _ in
                verifications.withValue { $0 += 1 }
                await Task.yield()
                identity = replacement
                return true
            },
            identity: { _ in identity }
        )).verifiedExpectedRuntime(for: .init(helper: helper, identity: original))

        XCTAssertNil(verified)
        XCTAssertEqual(verifications.value, 1)
    }

    @MainActor
    func testRuntimeObservationRejectsAnInstalledVersionDifferentFromCapturedVersion() throws {
        let bundleURL = try makeAmbientBundle(name: "Updated Since Capture", build: "149")
        let launchDate = Date(timeIntervalSince1970: 14_150)
        let identity = AmbientRuntimeIdentity(
            instanceIdentifier: UUID(),
            processIdentifier: 848,
            bundlePath: bundleURL.path,
            version: .init(marketing: "1.0.99", build: "148"),
            workflowVersion: ExtensionBridge.workflowVersion,
            launchedAt: launchDate
        )
        let helper = runtimeHelper(
            processIdentifier: identity.processIdentifier,
            bundleURL: bundleURL,
            launchDate: launchDate
        )
        let verifications = LockedTestValue(0)
        let validate: @MainActor @Sendable (URL) async -> Bool = { url in
            XCTAssertEqual(url, bundleURL)
            verifications.withValue { $0 += 1 }
            return true
        }
        let confirmed = NativeAgentLauncher(dependencies: launcherTestDependencies(
            validate: validate,
            helpers: { [helper] },
            identity: { _ in identity }
        )).isConfirmed(
            .init(url: bundleURL, version: identity.version),
            deadline: UInt64.max
        )
        XCTAssertFalse(confirmed)
        XCTAssertEqual(verifications.value, 0)

        let status = NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: validate,
                helper: { pid in
                ([helper]).first { $0.processIdentifier == pid }
            },
                identity: { _ in identity }
            )).observe(
                owner: try XCTUnwrap(identity.nativeDeliveryOwner),
                expected: .init(url: bundleURL, version: identity.version)
            )
        guard case .unidentified = status else {
            return XCTFail("An updated installed bundle must invalidate captured compatibility")
        }
        XCTAssertEqual(verifications.value, 0)
    }

    @MainActor
    func testReceiptOwnerMetadataIgnoresUnidentifiedOtherPath() async throws {
        let expectedURL = try makeAmbientBundle(name: "Expected", build: "149")
        let otherURL = try makeAmbientBundle(name: "Other Legacy", build: "148")
        let version = try XCTUnwrap(
            AmbientRuntimeIdentity.bundleVersion(at: expectedURL)
        )
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: .init(value: UUID()),
            owner: try nativeDeliveryOwner(runtime: UUID(), bundleURL: expectedURL)
        )

        let status = NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { $0 == expectedURL },
                helper: { pid in
                ([self.runtimeHelper(
                    processIdentifier: 836,
                    bundleURL: otherURL,
                    launchDate: Date(timeIntervalSince1970: 13_700)
                )]).first { $0.processIdentifier == pid }
            },
                identity: { _ in nil }
            )).observe(
                owner: receipt.owner,
                expected: .init(url: expectedURL, version: version)
            )

        guard case .absent = status else {
            return XCTFail("Unrelated helper must not fence recovery")
        }
    }

    @MainActor
    func testReceiptOwnerMetadataRetainsTrueUnknownOwnerAmbiguity() async throws {
        let expectedURL = try makeAmbientBundle(name: "Expected", build: "149")
        let version = try XCTUnwrap(
            AmbientRuntimeIdentity.bundleVersion(at: expectedURL)
        )
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: .init(value: UUID()),
            owner: try nativeDeliveryOwner(runtime: UUID(), bundleURL: expectedURL)
        )

        let status = NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { $0 == expectedURL },
                helper: { pid in
                ([self.runtimeHelper(
                    processIdentifier: receipt.owner.processIdentifier,
                    bundleURL: expectedURL,
                    launchDate: receipt.owner.processStartDate
                )]).first { $0.processIdentifier == pid }
            },
                identity: { _ in nil }
            )).observe(
                owner: receipt.owner,
                expected: .init(url: expectedURL, version: version)
            )

        guard case .unidentified = status else {
            return XCTFail("Possible owner must remain ambiguous")
        }
    }

    @MainActor
    func testNativeAgentResolutionStopsWhenClockReachesDeadlineBetweenChecks() async throws {
        let helperURL = try makeAmbientBundle(name: "Resolution Deadline Boundary", build: "148")
        let uptime = LockedTestValue<UInt64>(0)
        let helperReads = LockedTestValue(0)
        let target = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in
                    XCTFail("An expired resolution must not validate a helper")
                    return false
                },
                helpers: {
                    helperReads.withValue { $0 += 1 }
                    uptime.value = 50_000_000
                    return []
                },
                identity: { _ in nil },
                uptime: {
                    uptime.value
                },
                sleepUntil: { _ in XCTFail("An expired resolution must not sleep") }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: helperURL)),
            deadline: 50_000_000
        )
        XCTAssertNil(target)
        XCTAssertEqual(helperReads.value, 1)
    }

    func testMaintenanceStopsAtStoreLockContention() async throws {
        let profileIdentifier = UUID()
        let fixture = try makeFixture(id: 81)
        let handle = try accepted(await bridge.enqueue(
            ingress: try profileFixture(fixture, profileIdentifier: profileIdentifier).ingress, profileIdentifier: profileIdentifier
        )).handle
        let completed = await bridge.completeImmediate(handle: handle, resolution: immediateResolution(for: fixture.request))
        XCTAssertEqual(completed, .persisted)
        let url = profileURL(profileIdentifier)
        let original = try Data(contentsOf: url)
        clock.now.addTimeInterval(ExtensionBridge.responseExpiry)
        try await CrossProcessLockTestFixture.withHeldLock(
            at: rootURL.appendingPathComponent("bridge-v9.lock"),
            readyURL: rootURL.appendingPathComponent("holder-ready")
        ) {
            await self.bridge.performMaintenance()
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        await bridge.performMaintenance()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: Any])
        XCTAssertEqual((profile["records"] as? [Any])?.count, 0)
    }

    @MainActor
    func testSeparateProcessStoreLockFencesAccess() async throws {
        let fixture = try makeFixture(id: 80)
        let readyURL = rootURL.appendingPathComponent("holder-ready")
        let lockURL = rootURL.appendingPathComponent("bridge-v9.lock")
        let temporaryURL = rootURL.appendingPathComponent(".profile-write-\(UUID().uuidString.lowercased()).tmp")
        try await CrossProcessLockTestFixture.withHeldLock(
            at: lockURL,
            readyURL: readyURL
        ) {
            try Data("active write".utf8).write(to: temporaryURL)
            guard case .unavailable = await self.bridge.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: nil
            ) else { throw Failure.expectedValue }
            XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        }
        _ = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }
    #endif

    private func assertAdmissionRetryRequiresSynchronization(
        original: Fixture,
        retry: Fixture,
        admissionKind: ExtensionBridge.AdmissionKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let callbackProfileURL = defaultProfileURL
        let writes = LockedTestValue(0)
        let synchronizationAttempts = LockedTestValue(0)
        let failSynchronization = LockedTestValue(true)
        let writer = makeBridge(
            clock: { [clock = clock!] in clock.now },
            atomicWrite: { data, url in
                writes.withValue { $0 += 1 }
                try data.write(to: url, options: .atomic)
                throw Failure.injectedWrite
            },
            synchronizePublishedFile: { url in
                synchronizationAttempts.withValue { $0 += 1 }
                XCTAssertEqual(url, callbackProfileURL, file: file, line: line)
                if failSynchronization.value { throw Failure.injectedWrite }
                try ApprovalStoreTestPersistence.synchronize(url)
            }
        )
        guard case .unavailable = await writer.enqueue(
            ingress: original.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Initial admission must require synchronization", file: file, line: line) }
        let originalData = try Data(contentsOf: defaultProfileURL)
        guard case .available(let snapshots) = await writer.list(profileIdentifier: nil),
              snapshots.count == 1,
              let snapshot = snapshots.values.first else {
            return XCTFail("Expected one visible admission", file: file, line: line)
        }

        for _ in 0..<2 {
            guard case .unavailable = await writer.enqueue(
                ingress: retry.ingress,
                profileIdentifier: nil
            ) else { return XCTFail("Admission retries must require synchronization", file: file, line: line) }
        }
        XCTAssertEqual(synchronizationAttempts.value, 3, file: file, line: line)
        failSynchronization.value = false
        let recovered = try accepted(await writer.enqueue(
            ingress: retry.ingress,
            profileIdentifier: nil
        ), file: file, line: line)
        XCTAssertEqual(recovered.admissionKind, admissionKind, file: file, line: line)
        XCTAssertEqual(recovered.handle, snapshot.handle, file: file, line: line)
        XCTAssertEqual(recovered.nativeDeliveryNonce, snapshot.nativeDeliveryNonce, file: file, line: line)
        XCTAssertEqual(recovered.revisions, original.ingress.authority.revisions, file: file, line: line)
        XCTAssertTrue(recovered.approvalRequired, file: file, line: line)
        XCTAssertEqual(synchronizationAttempts.value, 4, file: file, line: line)
        XCTAssertEqual(writes.value, 1, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), originalData, file: file, line: line)
    }

    private func makeBridge(
        clock: @escaping @Sendable () -> Date = { Date() },
        atomicWrite: @escaping ExtensionRequestFileStore.AtomicWrite =
            ApprovalStoreTestPersistence.write,
        synchronizePublishedFile: @escaping @Sendable (URL) throws -> Void =
            ApprovalStoreTestPersistence.synchronize,
        readData: @escaping ExtensionRequestFileStore.ReadData =
            ExtensionRequestFileStore.defaultReadData,
        readFileSize: @escaping ExtensionRequestFileStore.ReadFileSize =
            ExtensionRequestFileStore.defaultReadFileSize
    ) -> ExtensionBridge {
        ExtensionBridge(store: ExtensionRequestFileStore(
            rootURL: rootURL,
            directoryBoundary: rootURL,
            dependencies: .init(
                clock: clock,
                atomicWrite: atomicWrite,
                synchronizePublishedFile: synchronizePublishedFile,
                readData: readData,
                readFileSize: readFileSize
            )
        ))
    }

    #if os(macOS)
    private func makeAmbientBundle(name: String, build: String) throws -> URL {
        let bundleURL = rootURL.appendingPathComponent(
            "\(name)-\(UUID().uuidString).app",
            isDirectory: true
        )
        let contentsURL = bundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "org.lil.wallet.ambient",
                "CFBundleShortVersionString": "1.0.99",
                "CFBundleVersion": build,
            ],
            format: .xml,
            options: 0
        )
        try data.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            options: .atomic
        )
        return bundleURL.standardizedFileURL
    }

    private func runtimeIdentity(
        processIdentifier: Int32,
        bundleURL: URL,
        launchDate: Date,
        workflowVersion: Int =
            ExtensionBridge.workflowVersion
    ) throws -> AmbientRuntimeIdentity {
        AmbientRuntimeIdentity(
            instanceIdentifier: UUID(),
            processIdentifier: processIdentifier,
            bundlePath: bundleURL.standardizedFileURL.path,
            version: try XCTUnwrap(
                AmbientRuntimeIdentity.bundleVersion(at: bundleURL)
            ),
            workflowVersion: workflowVersion,
            launchedAt: launchDate
        )
    }

    private func nativeDeliveryOwner(
        runtime: UUID = UUID(),
        bundleURL: URL
    ) throws -> ExtensionBridge.NativeDeliveryOwner {
        let version = try XCTUnwrap(
            AmbientRuntimeIdentity.bundleVersion(at: bundleURL)
        )
        return try XCTUnwrap(ExtensionBridge.NativeDeliveryOwner(
            runtimeInstanceIdentifier: runtime,
            processIdentifier: 42,
            processStartDate: Date(timeIntervalSince1970: 1_800_000_000),
            bundleURL: bundleURL,
            marketingVersion: version.marketing,
            buildVersion: version.build
        ))
    }

    private func runtimeHelper(
        processIdentifier: Int32,
        bundleURL: URL,
        launchDate: Date,
        isRunning: @escaping @MainActor @Sendable () -> Bool = { true },
        requestQuit: @escaping @MainActor @Sendable () -> Bool = { false }
    ) -> NativeAgentLauncher.RuntimeHelper {
        NativeAgentLauncher.RuntimeHelper(
            processIdentifier: processIdentifier,
            bundleURL: bundleURL,
            processStartDate: launchDate,
            isRunning: isRunning,
            requestQuit: requestQuit
        )
    }
    #endif

    private var knownAuthority = [String: ExtensionBridge.AuthorityVersion]()

    private func profileFixture(_ fixture: Fixture, profileIdentifier: UUID?) throws -> Fixture {
        if case .ethereum(let body) = fixture.request.body, body.method == .signTransaction {
            try seedTransactionAuthority(configurationKey: fixture.request.configurationKey, profileIdentifier: profileIdentifier)
        }
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.ingress.canonicalData) as? [String: Any])
        raw["authority"] = try authorityVersion(fixture.request.configurationKey, profileIdentifier: profileIdentifier).json
        if fixture.ingress.replayOnly { raw["replayOnly"] = true }
        return try authorityFixture(raw)
    }

    private func authorityVersion(_ configurationKey: String, profileIdentifier: UUID? = nil) throws -> ExtensionBridge.AuthorityVersion {
        let key = (profileIdentifier?.uuidString ?? "default") + configurationKey
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL,
            dependencies: .init(clock: { [clock = clock!] in clock.now }, atomicWrite: ApprovalStoreTestPersistence.write))
        if case .snapshot(let snapshot) = store.configurationSnapshot(configurationKey: configurationKey, profileIdentifier: profileIdentifier) {
            knownAuthority[key] = snapshot.version
            return snapshot.version
        }
        return try XCTUnwrap(knownAuthority[key])
    }

    private func makeFixture(
        id: Int,
        name: String = "ecRecover",
        host: String = "wallet.example",
        configurationKey: String? = nil,
        enqueueAttempt: String? = nil,
        admissionDeadline: Date? = nil,
        message: String = "0x48656c6c6f",
        replayOnly: Bool = false
    ) throws -> Fixture {
        let configurationKey = configurationKey ?? "https://\(host)"
        var object: [String: Any] = [
            "id": id,
            "name": name,
            "provider": "ethereum",
            "host": host,
            "configurationKey": configurationKey,
            "enqueueAttempt": enqueueAttempt ?? attempt(for: id),
            "admissionDeadline": Int(
                (admissionDeadline ?? clock.now.addingTimeInterval(
                    ExtensionBridge.requestTTL
                )).timeIntervalSince1970 * 1_000
            ),
            "workflowVersion": ExtensionBridge.workflowVersion,
            "authority": try authorityVersion(configurationKey).json,
            "body": [
                "address": "0x0000000000000000000000000000000000000042",
                "object": ["data": message],
            ],
        ]
        if replayOnly { object["replayOnly"] = true }
        let request = try XCTUnwrap(SafariRequest(json: object))
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(
            request: request,
            rawObject: object
        ) else { throw Failure.expectedValue }
        return Fixture(request: request, ingress: ingress)
    }

    @MainActor
    private final class StorageBroadcastSender: ApprovedBroadcastSending {
        var calls = 0
        var ethereumResult: Result<String, EthereumSendFailure>?

        func sendEthereum(signedTransaction: String, network: ResolvedEthereumNetwork) async -> Result<String, EthereumSendFailure> {
            calls += 1
            return ethereumResult ?? .success(Ethereum.transactionHash(signedTransaction: signedTransaction)!)
        }

        func sendSolana(signedTransaction: String, cluster: Solana.Cluster, options: Solana.PreparedSendOptions) async -> Result<String, Solana.SendTransactionError> {
            calls += 1
            return .success(Solana.transactionSignature(signedTransaction: signedTransaction)!)
        }
    }

    @MainActor
    private final class StorageExecutionProcessor: DappRequestProcessing {
        let broadcasts: Bool
        var calls = 0

        init(broadcasts: Bool) { self.broadcasts = broadcasts }

        func prepare(_ binding: ExtensionBridge.RequestBinding, catalog: WalletReviewCatalog) -> DappRequestPreparation {
            DappRequestProcessor().prepare(binding, catalog: catalog)
        }

        func prepareWithoutWallets(_ binding: ExtensionBridge.RequestBinding) -> DappRequestPreparation? {
            DappRequestProcessor().prepareWithoutWallets(binding)
        }

        func execute(permit: ExtensionBridge.ApprovedExecutionPermit, signer: (any WalletSigning)?) async -> ApprovedExecutionResult {
            guard permit.consumeExecution() else { return .rollback }
            calls += 1
            if broadcasts {
                guard let signer, case .success(.broadcast(let signed)) = await signer.sign() else { return .rollback }
                return .broadcast(PreparedBroadcast(signed: signed))
            }
            guard let completion = ApprovedCompletion.failure(.userRejected, permit: permit) else { return .rollback }
            return .completed(completion)
        }
    }

    @discardableResult
    private func seedTransactionAuthority(configurationKey: String, profileIdentifier: UUID? = nil) throws -> String {
        let version = try authorityVersion(configurationKey, profileIdentifier: profileIdentifier)
        let url = profileURL(profileIdentifier)
        var profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        var origins = try XCTUnwrap(profile["origins"] as? [String: Any])
        var origin = origins[configurationKey] as? [String: Any] ?? [
            "revisions": version.revisions.json,
            "ethereumChainId": "0x1",
        ]
        if origin["ethereumAccount"] == nil {
            let accountData = try PropertyListEncoder().encode(authorityTestAccount())
            origin["ethereumAccount"] = try PropertyListSerialization.propertyList(from: accountData, format: nil)
            origins[configurationKey] = origin
            profile["origins"] = origins
            try PropertyListSerialization.data(fromPropertyList: profile, format: .binary, options: 0)
                .write(to: url, options: .atomic)
        }
        return origin["ethereumChainId"] as? String ?? "0x1"
    }

    private func makeTransactionFixture(
        id: Int,
        host: String = "wallet.example",
        configurationKey: String? = nil,
        enqueueAttempt: String? = nil,
        admissionDeadline: Date? = nil,
        message: String = "0x",
        replayOnly: Bool = false
    ) throws -> Fixture {
        let configurationKey = configurationKey ?? "https://\(host)"
        let account = authorityTestAccount()
        let chainID = try seedTransactionAuthority(configurationKey: configurationKey)
        let template = try makeFixture(
            id: id, host: host, configurationKey: configurationKey,
            enqueueAttempt: enqueueAttempt, admissionDeadline: admissionDeadline,
            message: message, replayOnly: replayOnly
        )
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: template.ingress.canonicalData) as? [String: Any])
        raw["name"] = "signTransaction"
        raw["body"] = [
            "address": account.normalizedAddress,
            "chainId": chainID,
            "object": ["from": account.normalizedAddress,
                       "to": "0x0000000000000000000000000000000000000001",
                       "nonce": "0x0", "gas": "0x5208", "gasPrice": "0x1",
                       "value": "0x0", "data": message],
        ]
        if replayOnly { raw["replayOnly"] = true }
        return try authorityFixture(raw)
    }

    private final class ReviewedExecution: Sendable {
        let permit: ExtensionBridge.ApprovedExecutionPermit
        let completion: ApprovedCompletion
        let approval: ResolvedDappApproval
        let broadcast: PreparedBroadcast?
        let recovery: ApprovedCompletion?
        private let storedDispatch = Mutex<ExtensionBridge.BroadcastDispatchPermit?>(nil)
        var dispatch: ExtensionBridge.BroadcastDispatchPermit? {
            get { storedDispatch.withLock { $0 } }
            set { storedDispatch.withLock { $0 = newValue } }
        }

        init(
            permit: ExtensionBridge.ApprovedExecutionPermit,
            completion: ApprovedCompletion,
            approval: ResolvedDappApproval,
            broadcast: PreparedBroadcast? = nil,
            recovery: ApprovedCompletion? = nil
        ) {
            self.permit = permit
            self.completion = completion
            self.approval = approval
            self.broadcast = broadcast
            self.recovery = recovery
        }

        var request: SafariRequest { permit.request }
        var executionDeadline: Date { permit.executionDeadline }
        var authority: ExtensionBridge.ExecutionAuthority { permit.authority }
        var handle: ExtensionBridge.Handle { permit.handle }
        var response: ResponseToExtension { completion.response(for: permit)! }
        var recoveryResponse: ResponseToExtension { recovery!.response(for: permit)! }
        func releaseLease() { permit.releaseLease() }
    }

    private static func preparedTransactionForStorage(_ action: SendTransactionAction) -> Transaction {
        var transaction = action.transaction
        transaction.nonce = transaction.nonce ?? "0x0"
        transaction.gas = transaction.gas ?? "0x5208"
        let fee = transaction.feeIntent.preparedFee ?? .legacy(gasPrice: 1)
        transaction.replacePreparedFee(fee, provenance: .init(source: .dapp, for: fee))
        transaction.currentBaseFeePerGas = 0
        return transaction
    }

    @MainActor
    private static func reviewedConsent(
        _ snapshot: ExtensionBridge.Snapshot,
        approvedAt: Date,
        accounts: [WalletAccountDescriptor]? = nil,
        chainID: String = "0x1",
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt? = nil
    ) throws -> ReviewConsent {
        let request = try XCTUnwrap(snapshot.request)
        let descriptors = accounts ?? request.authorizedAccount.map { [$0] } ?? []
        let catalog = WalletReviewCatalog(
            identity: .init(generation: nil, catalogData: Data()),
            orderedAccounts: descriptors.map(\.specificAccount)
        )
        let processor = DappRequestProcessor(ethereumNetworkResolver: { chainID in
            if case .ethereum(let body) = request.body, body.method == .addEthereumChain {
                return .missing
            }
            return NetworkResolver.main.approvalResolution(chainId: chainID)
        })
        guard case .approval(let intent) = processor.prepare(
            try XCTUnwrap(snapshot.requestBinding), catalog: catalog
        ) else { throw Failure.expectedValue }
        let action = intent.action
        let decision: DappApprovalDecision
        switch action {
        case .selectAccount, .switchAccount:
            decision = .accountSelection(.init(accounts: descriptors, ethereumChainID: chainID))
        case .approveMessage(let message):
            decision = .message(.init(
                approvedAccount: .init(walletID: message.walletId, account: message.account),
                solanaCluster: message.solanaClusterOptions == nil ? nil : .mainnetBeta
            ))
        case .approveTransaction(let transaction):
            decision = .transaction(try XCTUnwrap(DappApprovalDecision.TransactionExecution(
                Self.preparedTransactionForStorage(transaction), reviewedNetwork: transaction.resolvedNetwork,
                approvedAccount: .init(walletID: transaction.walletId, account: transaction.account)
            )))
        case .addEthereumChain: decision = .addEthereumChain
        }
        return try reviewConsentForTesting(
            snapshot: snapshot, action: action, decision: decision,
            approvedAt: approvedAt, nativeReceipt: nativeReceipt ?? snapshot.nativeDeliveryReceipt
        )
    }

    @MainActor
    private func reviewedApproval(
        _ claim: ExtensionBridge.ApprovalClaim,
        accounts: [WalletAccountDescriptor]? = nil,
        chainID: String = "0x1"
    ) throws -> ResolvedDappApproval {
        let store = removalStore()
        guard case .found(let snapshot) = store.load(handle: claim.handle) else { throw Failure.expectedValue }
        let approvedAt: Date
        if case .native(let value, _) = claim.authority { approvedAt = value }
        else { approvedAt = clock.now }
        let consent: ReviewConsent
        if case .native = claim.authority {
            consent = try XCTUnwrap(nativeClaimConsents.value.first(where: { $0.claim == claim })?.consent)
        } else {
            consent = try Self.reviewedConsent(snapshot, approvedAt: approvedAt, accounts: accounts, chainID: chainID)
        }
        let descriptors = accounts ?? claim.request.authorizedAccount.map { [$0] } ?? []
        return try consent.resolve(
            context: approvalResolutionContextForTesting(
                action: consent.intent.action,
                decision: consent.decision,
                accounts: descriptors.map(\.specificAccount)
            )
        ).get()
    }

    @MainActor
    private func reviewedExecution(
        _ claim: ExtensionBridge.ApprovalClaim,
        accounts: [WalletAccountDescriptor]? = nil,
        chainID: String = "0x1"
    ) async throws -> ReviewedExecution {
        let store = removalStore()
        let resolved = try reviewedApproval(claim, accounts: accounts, chainID: chainID)
        guard claim.adoptForExecution(),
              case .authorized(let permit) = store.authorize(claim: claim, approval: resolved),
              permit.consumeExecution() else { throw Failure.expectedValue }
        let completion: ApprovedCompletion
        var broadcast: PreparedBroadcast?
        switch permit.approval.kind {
        case .accountSelection:
            completion = try XCTUnwrap(ApprovedCompletion.accountSelection(permit: permit))
        case .addEthereumChain:
            completion = try XCTUnwrap(ApprovedCompletion.chainAdded(permit: permit))
        case .signing:
            switch try await walletSigningOutputForTesting(permit: permit, clock: { [clock = clock!] in clock.now }) {
            case .response(let signed):
                completion = ApprovedCompletion(signed: signed)
            case .broadcast(let signed):
                broadcast = PreparedBroadcast(signed: signed)
                completion = try XCTUnwrap(broadcast?.recoveryCompletion(for: permit))
            }
        }
        return ReviewedExecution(
            permit: permit, completion: completion, approval: resolved,
            broadcast: broadcast, recovery: broadcast?.recoveryCompletion(for: permit)
        )
    }

    @MainActor
    private func completeApprovedSelection(handle: ExtensionBridge.Handle, accounts: [WalletAccountDescriptor], chainID: String = "0x1") async throws -> ExtensionBridge.StoreMutationResult {
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        let execution = try await reviewedExecution(claim, accounts: accounts, chainID: chainID)
        return await completeReviewedExecution(execution)
    }

    private func prepareReviewedBroadcast(
        _ execution: ReviewedExecution,
        in writer: ExtensionBridge? = nil
    ) async -> ExtensionBridge.StoreMutationResult {
        guard let broadcast = execution.broadcast else { return .ownershipLost }
        switch await (writer ?? bridge).prepareBroadcast(permit: execution.permit, broadcast: broadcast) {
        case .prepared(let dispatch):
            execution.dispatch = dispatch
            return .persisted
        case .ownershipLost: return .ownershipLost
        case .retryablePersistenceFailure: return .retryablePersistenceFailure
        }
    }

    private func prepareReviewedBroadcast(
        _ execution: ReviewedExecution,
        in writer: ExtensionRequestFileStore
    ) -> ExtensionBridge.StoreMutationResult {
        guard let broadcast = execution.broadcast else { return .ownershipLost }
        switch writer.prepareBroadcast(permit: execution.permit, broadcast: broadcast) {
        case .prepared(let dispatch):
            execution.dispatch = dispatch
            return .persisted
        case .ownershipLost: return .ownershipLost
        case .retryablePersistenceFailure: return .retryablePersistenceFailure
        }
    }

    private func completeReviewedExecution(
        _ execution: ReviewedExecution,
        result: ApprovedCompletion? = nil,
        in writer: ExtensionRequestFileStore
    ) -> ExtensionBridge.StoreMutationResult {
        writer.complete(permit: execution.permit, result: result ?? execution.completion)
    }

    private func completeReviewedExecution(
        _ execution: ReviewedExecution,
        result: ApprovedCompletion? = nil,
        in writer: ExtensionBridge? = nil
    ) async -> ExtensionBridge.StoreMutationResult {
        await (writer ?? bridge).complete(permit: execution.permit, result: result ?? execution.completion)
    }

    private func recordNativeDelivery(handle: ExtensionBridge.Handle) async throws -> ExtensionBridge.StoreMutationResult {
        guard case .found(let snapshot) = await bridge.load(handle: handle) else {
            throw Failure.expectedValue
        }
        let runtime = snapshot.nativeDeliveryReceipt?.owner.runtimeInstanceIdentifier ?? UUID()
        return await bridge.recordNativeDeliveryReceipt(
            handle: handle,
            nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
            owner: storedRequestNativeOwner(runtime: runtime)
        )
    }

    private func nativeConsent(
        handle: ExtensionBridge.Handle,
        approvedAt: Date,
        receipt: ExtensionBridge.NativeDeliveryReceipt? = nil
    ) async throws -> ReviewConsent {
        guard case .found(let snapshot) = await bridge.load(handle: handle) else {
            throw Failure.expectedValue
        }
        return try await Self.reviewedConsent(snapshot, approvedAt: approvedAt, nativeReceipt: receipt)
    }

    private func claimDeliveredNativeExecution(
        in store: ExtensionBridge,
        handle: ExtensionBridge.Handle,
        approvedAt: Date
    ) async -> ExtensionBridge.NativeExecutionClaimResult {
        let snapshot: ExtensionBridge.Snapshot
        switch await store.load(handle: handle) {
        case .found(let value): snapshot = value
        case .missing: return .missing
        case .unavailable: return .unavailable
        }
        if snapshot.phase == .responded { return .responded }
        guard let receipt = snapshot.nativeDeliveryReceipt else { return .ownershipLost }
        guard let consent = try? await Self.reviewedConsent(snapshot, approvedAt: approvedAt, nativeReceipt: receipt) else {
            XCTFail("Expected a reviewable native request")
            return .ownershipLost
        }
        let result = await store.claimNativeExecution(consent: consent)
        if case .claimed(let claim) = result {
            nativeClaimConsents.withValue { $0.append((claim, consent)) }
        }
        return result
    }

    private func nativeApproval(
        _ claim: ExtensionBridge.ApprovalClaim
    ) throws -> (approvedAt: Date, context: ExtensionBridge.NativeExecutionContext) {
        guard case .native(let approvedAt, let context) = claim.authority else {
            throw Failure.expectedValue
        }
        return (approvedAt, context)
    }

    @MainActor
    private func makeExecutableNativePermit(
        id: Int
    ) async throws -> (
        request: SafariRequest,
        handle: ExtensionBridge.Handle,
        permit: ReviewedExecution
    ) {
        let fixture = try makeTransactionFixture(id: id)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let delivered = try await recordNativeDelivery(handle: handle)
        XCTAssertEqual(delivered, .persisted)
        let nativeClaim: ExtensionBridge.ApprovalClaim
        switch await claimDeliveredNativeExecution(in: bridge, handle: handle, approvedAt: clock.now) {
        case .claimed(let value):
            nativeClaim = value
        case .ownershipLost, .executing, .responded, .missing, .unavailable, .reviewRequired:
            throw Failure.expectedValue
        }
        let permit = try await reviewedExecution(nativeClaim)
        return (
            fixture.request,
            handle,
            permit
        )
    }

    private func makeManualFixture(
        id: Int,
        enqueueAttempt: String,
        latestConfigurations: [[String: Any]],
        host: String = "wallet.example",
        configurationKey: String = "https://wallet.example",
        admissionDeadline: Date? = nil
    ) throws -> Fixture {
        let object: [String: Any] = [
            "id": id,
            "name": "switchAccount",
            "provider": "unknown",
            "host": host,
            "configurationKey": configurationKey,
            "enqueueAttempt": enqueueAttempt,
            "admissionDeadline": Int(
                (admissionDeadline ?? clock.now.addingTimeInterval(
                    ExtensionBridge.requestTTL
                )).timeIntervalSince1970 * 1_000
            ),
            "workflowVersion": ExtensionBridge.workflowVersion,
            "authority": try authorityVersion(configurationKey).json,
            "body": ["latestConfigurations": latestConfigurations],
        ]
        let request = try XCTUnwrap(SafariRequest(json: object))
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(
            request: request,
            rawObject: object
        ) else { throw Failure.expectedValue }
        return Fixture(request: request, ingress: ingress)
    }

    private func recoveryRequests(
        _ result: ExtensionBridge.RecoveryRequestsResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [ExtensionBridge.RecoveryRequest] {
        guard case .available(let page) = result else {
            XCTFail("Expected recovery requests", file: file, line: line)
            throw Failure.expectedValue
        }
        return page
    }

    private func attempt(for id: Int) -> String {
        let suffix = String(id, radix: 16)
        return String(repeating: "0", count: 32 - suffix.count) + suffix
    }

    private func accepted(
        _ result: ExtensionBridge.EnqueueResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (
        handle: ExtensionBridge.Handle,
        approvalRequired: Bool,
        revisions: ExtensionBridge.ProviderRevisions,
        admissionKind: ExtensionBridge.AdmissionKind,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
    ) {
        guard case .accepted(
            let handle,
            let approvalRequired,
            let revisions,
            let admissionKind,
            let nativeDeliveryNonce
        ) = result else {
            XCTFail("Expected accepted enqueue", file: file, line: line)
            throw Failure.expectedValue
        }
        return (
            handle,
            approvalRequired,
            revisions.version.revisions,
            admissionKind,
            nativeDeliveryNonce
        )
    }

    private func approvalClaim(
        _ result: ExtensionBridge.ApprovalClaimResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ExtensionBridge.ApprovalClaim {
        guard case .claimed(let claim) = result else {
            XCTFail("Expected claim", file: file, line: line)
            throw Failure.expectedValue
        }
        return claim
    }

    private var largeResponseResult: String {
        String(repeating: "a", count: ExtensionBridge.maximumPayloadBytes - 1024)
    }

    private func largeResponse(for request: SafariRequest) -> ResponseToExtension {
        largeImmediateResolution(for: request).response(for: request)!
    }

    private func fillCompletedByteCapacity(
        startingID: Int = 0,
        host: String? = nil
    ) async throws -> [(fixture: Fixture, handle: ExtensionBridge.Handle)] {
        var completed = [(fixture: Fixture, handle: ExtensionBridge.Handle)]()
        for id in startingID..<(startingID + 64) {
            var fixture = try makeFixture(id: id, host: host ?? "capacity-\(id).example")
            var result = await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)
            if case .unauthorized = result {
                fixture = try makeFixture(id: id, host: host ?? "capacity-\(id).example")
                result = await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)
            }
            if case .rejected = result { return completed }
            let handle = try accepted(result).handle
            let completion = await bridge.completeImmediate(
                handle: handle,
                resolution: largeImmediateResolution(for: fixture.request)
            )
            XCTAssertEqual(completion, .persisted)
            completed.append((fixture, handle))
        }
        XCTFail("Expected bounded completed-response byte capacity")
        throw Failure.expectedValue
    }

    private func immediateResolution(for request: SafariRequest) -> ImmediateResolution {
        if case .ethereum(let body) = request.body, body.method == .ecRecover {
            return .ethereumRecoveredAddress("0xsigned")
        }
        return .failure(.userRejected)
    }

    private func response(for request: SafariRequest) -> ResponseToExtension {
        immediateResolution(for: request).response(for: request)!
    }

    private func largeImmediateResolution(for request: SafariRequest) -> ImmediateResolution {
        .failure(.init(message: largeResponseResult, code: -32_000))
    }

    private func responseJSON(
        _ result: ExtensionBridge.ResponseReadResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        guard case .response(let response) = result else {
            XCTFail("Expected response", file: file, line: line)
            throw Failure.expectedValue
        }
        return try XCTUnwrap(response["response"] as? [String: Any], file: file, line: line)
    }

    private var defaultProfileURL: URL {
        profileURL(nil)
    }

    private var revocationLedgerURL: URL {
        rootURL.appendingPathComponent("wallet-authority-revocations.state")
    }

    private func storedRevocationLedger() throws -> WalletAuthorityRevocationLedger {
        try XCTUnwrap(WalletAuthorityRevocationLedger.decode(Data(contentsOf: revocationLedgerURL)))
    }

    private func profileURL(_ profileIdentifier: UUID?) -> URL {
        let name = profileIdentifier?.uuidString.lowercased() ?? "default"
        return rootURL
            .appendingPathComponent("profiles-v9", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("state")
    }

    private func operationLockURL(_ handle: ExtensionBridge.Handle) -> URL {
        let profile = handle.profileIdentifier?.uuidString.lowercased() ?? "default"
        return rootURL
            .appendingPathComponent("operation-locks-v9", isDirectory: true)
            .appendingPathComponent("\(profile)-\(handle.token.rawValue)")
            .appendingPathExtension("lock")
    }

    private func firstStoredCreatedAt() throws -> Date {
        let profile = try storedProfile()
        let records = try XCTUnwrap(profile["records"] as? [[String: Any]])
        return try XCTUnwrap(records.first?["createdAt"] as? Date)
    }

    private func mutateStoredPermissions(
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws {
        var profile = try storedProfile()
        var origins = try XCTUnwrap(profile["origins"] as? [String: Any])
        try mutation(&origins)
        profile["origins"] = origins
        let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .binary, options: 0)
        try data.write(to: defaultProfileURL, options: .atomic)
    }

    private func mutateFirstStoredRecord(
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws {
        var profile = try storedProfile()
        var records = try XCTUnwrap(profile["records"] as? [[String: Any]])
        guard !records.isEmpty else { throw Failure.expectedValue }
        try mutation(&records[0])
        profile["records"] = records
        let data = try PropertyListSerialization.data(
            fromPropertyList: profile,
            format: .binary,
            options: 0
        )
        try data.write(to: defaultProfileURL, options: .atomic)
    }

    private func bodyData(for ingress: ExtensionBridge.Ingress) throws -> Data {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: ingress.canonicalData) as? [String: Any])
        return try XCTUnwrap(ExtensionBridge.payloadData(try XCTUnwrap(object["body"] as? [String: Any]), options: [.sortedKeys]))
    }

    private func firstStoredBody(_ state: String) throws -> Data {
        let request = try XCTUnwrap(firstStoredState(state)["request"] as? [String: Any])
        return try XCTUnwrap(request["bodyData"] as? Data)
    }

    private func firstStoredState(_ name: String) throws -> [String: Any] {
        let profile = try storedProfile()
        let records = try XCTUnwrap(profile["records"] as? [[String: Any]])
        let state = try XCTUnwrap(records.first?["state"] as? [String: Any])
        return try XCTUnwrap(state[name] as? [String: Any])
    }

    private func assertStoredProfileUnavailableAndUnchanged(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let original = try Data(contentsOf: defaultProfileURL)
        let observer = makeBridge(clock: { [clock = clock!] in clock.now })
        guard case .unavailable = await observer.list(profileIdentifier: nil) else {
            return XCTFail("Expected malformed profile to be unavailable", file: file, line: line)
        }
        guard case .unavailable = await observer.enqueue(
            ingress: try makeFixture(id: 734, name: "requestAccounts").ingress,
            profileIdentifier: nil
        ) else {
            return XCTFail("Expected admission to preserve malformed profile", file: file, line: line)
        }
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original, file: file, line: line)
    }

    private func firstStoredNativeApproval(_ state: String) throws -> [String: Any] {
        let payload = try firstStoredState(state)
        let approval = try XCTUnwrap(payload["approval"] as? [String: Any])
        let native = try XCTUnwrap(
            approval["native"] as? [String: Any]
        )
        return try XCTUnwrap(native["_0"] as? [String: Any])
    }

    private func mutateFirstStoredState(
        _ name: String,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws {
        try mutateFirstStoredRecord { record in
            var state = try XCTUnwrap(record["state"] as? [String: Any])
            var payload = try XCTUnwrap(state[name] as? [String: Any])
            try mutation(&payload)
            state[name] = payload
            record["state"] = state
        }
    }

    private func storedProfile() throws -> [String: Any] {
        let data = try Data(contentsOf: defaultProfileURL)
        return try XCTUnwrap(PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any])
    }
}
