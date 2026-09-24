// ∅ 2026 lil org

import Foundation
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

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private final class RequestParseRecorder {
        private var ids = [Int]()

        func parse(_ json: [String: Any]) -> SafariRequest? {
            ids.append(json["id"] as? Int ?? -1)
            return SafariRequest(json: json)
        }

        func takeIDs() -> [Int] {
            defer { ids.removeAll() }
            return ids
        }
    }

    private struct Fixture {
        let request: SafariRequest
        let ingress: ExtensionBridge.Ingress
    }

    private var rootURL: URL!
    private var clock: Clock!
    private var bridge: ExtensionBridge!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "extension-bridge-v7-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        clock = Clock()
        let testClock = clock!
        bridge = makeBridge(clock: { testClock.now })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
        bridge = nil
        clock = nil
        rootURL = nil
        try super.tearDownWithError()
    }

    func testAuthorityBootstrapPersistsOnlyProfileIdentityAndWarmReadsAreReadOnly() throws {
        var writes = 0
        var synchronizations = 0
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { self.clock.now },
            atomicWrite: { data, url in writes += 1; try ApprovalStoreTestPersistence.write(data, url) },
            synchronizePublishedFile: { _ in synchronizations += 1 }
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
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(synchronizations, 0)
        XCTAssertEqual(first.version, second.version)
        XCTAssertNotEqual(first.version.context, other.version.context)
        XCTAssertEqual((try storedProfile()["origins"] as? [String: Any])?.count, 0)
        XCTAssertNil(first.ethereumAccount)
        XCTAssertNil(first.solanaAccount)
    }

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
                let permit = try executionPermit(await bridge.begin(claim: claim))
                let broadcast = try await admit(baseID + index * 5 + 3)
                let broadcastClaim = try approvalClaim(await bridge.claim(handle: broadcast.handle))
                let broadcastPermit = try executionPermit(await bridge.begin(claim: broadcastClaim))
                let recovery = ambiguousSubmissionResponse(for: broadcast.request, transactionHash: "0xgrant-check")
                    .markingApprovalCommitted()
                let checkpoint = await bridge.prepareBroadcast(permit: broadcastPermit, recoveryResponse: recovery, authority: .ordinary)
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
                _ = await bridge.complete(permit: permit, response: response(for: claimed.request).markingApprovalCommitted(), authority: .ordinary)
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

        var removed = false
        try removalStore().withRevokedWalletAuthority(matching: .wallet(id: "unrelated-wallet")) { removed = true }
        XCTAssertTrue(removed)
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
                  let request = snapshot.request,
                  case .approval(.switchAccount(let action)) = processor.prepare(request, catalog: catalog) else {
                return XCTFail("Expected the persisted manual switch")
            }
            XCTAssertEqual(Set(action.selectedAccounts.map {
                WalletAccountDescriptor(walletID: $0.walletId, account: $0.account)
            }), Set(granted))
            let missingGrantedAccounts = WalletReviewCatalog(
                identity: catalog.identity, orderedAccounts: duplicates.map(\.specificAccount)
            )
            guard case .approval(.switchAccount(let unavailable)) = processor.prepare(request, catalog: missingGrantedAccounts) else {
                return XCTFail("Expected manual selection without the granted wallets")
            }
            XCTAssertTrue(unavailable.selectedAccounts.isEmpty)

            let decision = DappApprovalDecision.accountSelection(.init(
                accounts: action.selectedAccounts.map {
                    .init(walletID: $0.walletId, address: $0.account.address,
                          provider: $0.account.coin.correspondingInpageProvider, derivationPath: $0.account.derivationPath)
                },
                ethereumChainID: chainID
            ))
            let approval = try DappApprovalValidator.resolve(
                action: .switchAccount(action), decision: decision, accounts: catalog.orderedAccounts,
                networkResolver: { Networks.withChainIdHex($0) }
            ).get()
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            let permit = try executionPermit(await bridge.begin(claim: claim))
            guard case .response(let response, _) = await processor.execute(request: request, approval: approval, signer: nil) else {
                return XCTFail("Expected the approved account selection")
            }
            let completion = await bridge.complete(permit: permit, response: response.markingApprovalCommitted(), authority: .ordinary)
            XCTAssertEqual(completion, .persisted)
            let current = try await removalSnapshot()
            XCTAssertEqual(current.ethereumAccount, ethereum)
            XCTAssertEqual(current.solanaAccount, solana)
            XCTAssertEqual(current.ethereumChainId, chainID)
            let acknowledged = await bridge.acknowledgeResponse(handle: handle, configurationKey: request.configurationKey)
            XCTAssertEqual(acknowledged, .persisted)
        }

        let beforeRemoval = try await removalSnapshot()
        try removalStore().withRevokedWalletAuthority(matching: .wallet(id: "first-wallet")) {}
        let afterRemoval = try await removalSnapshot()
        XCTAssertEqual(afterRemoval.version, beforeRemoval.version)
        XCTAssertEqual(afterRemoval.ethereumAccount, ethereum)
        XCTAssertEqual(afterRemoval.solanaAccount, solana)
    }

    func testMalformedPermissionsDisconnectOnlyAffectedOriginAndPermitReconnection() async throws {
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
            XCTAssertEqual(retained.ethereumAccount, account)
            XCTAssertEqual(retained.ethereumChainId, healthy.ethereumChainId)
            XCTAssertEqual(retained.version, healthy.version)
            XCTAssertEqual(try Data(contentsOf: profileURL(otherProfile)), otherProfileData)
            let repeated = try await removalSnapshot()
            XCTAssertEqual(repeated.version, recovered.version)
        }

        _ = try await grantAuthority(account, id: 64_004)
        let reconnected = try await removalSnapshot()
        XCTAssertEqual(reconnected.ethereumAccount, account)
        XCTAssertNil(reconnected.solanaAccount)
    }

    func testIncompatiblePermissionContainerDisconnectsAllOriginsWithoutDiscardingRequestHistory() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 64_050)
        _ = try await grantAuthority(account, id: 64_051, host: "second.example")
        let completed = try makeFixture(id: 64_052)
        let completedHandle = try accepted(await bridge.enqueue(ingress: completed.ingress, profileIdentifier: nil)).handle
        let completion = await bridge.complete(handle: completedHandle, response: response(for: completed.request))
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
                }
                let repeated = try await removalSnapshot()
                XCTAssertEqual(repeated.version, recovered.version)
            }
        }
    }

    func testPermissionRecoveryFencesOutstandingApprovalsWithoutLosingBroadcastOrCompletedResponses() async throws {
        let account = authorityTestAccount()
        let grant = try await grantAuthority(account, id: 64_010)
        let completed = try makeFixture(id: 64_011)
        let completedHandle = try accepted(await bridge.enqueue(ingress: completed.ingress, profileIdentifier: nil)).handle
        let completion = await bridge.complete(handle: completedHandle, response: response(for: completed.request))
        XCTAssertEqual(completion, .persisted)
        let completedResponse = try await deliveredAuthority(completedHandle)
        let pending = try await admittedSigning(account, id: 64_012)
        let claimed = try await admittedSigning(account, id: 64_013)
        let claim = try approvalClaim(await bridge.claim(handle: claimed.handle))
        let permit = try executionPermit(await bridge.begin(claim: claim))
        let selection = try makeFixture(id: 64_014, name: "requestAccounts")
        let selectionHandle = try accepted(await bridge.enqueue(ingress: selection.ingress, profileIdentifier: nil)).handle
        let selectionClaim = try approvalClaim(await bridge.claim(handle: selectionHandle))
        let selectionPermit = try executionPermit(await bridge.begin(claim: selectionClaim))
        let broadcast = try makeFixture(id: 64_015, name: "signPersonalMessage")
        let broadcastHandle = try accepted(await bridge.enqueue(ingress: broadcast.ingress, profileIdentifier: nil)).handle
        let broadcastClaim = try approvalClaim(await bridge.claim(handle: broadcastHandle))
        let broadcastPermit = try executionPermit(await bridge.begin(claim: broadcastClaim))
        let recovery = ambiguousSubmissionResponse(for: broadcast.request, transactionHash: "0xpermission-recovery")
            .markingApprovalCommitted()
        let checkpoint = await bridge.prepareBroadcast(permit: broadcastPermit, recoveryResponse: recovery, authority: .ordinary)
        XCTAssertEqual(checkpoint, .persisted)
        let originalRecords = try XCTUnwrap(storedProfile()["records"] as? [[String: Any]])
        let originalCheckpoint = try XCTUnwrap(originalRecords.first { $0["id"] as? Int == broadcast.request.id })
        let originalCompleted = try XCTUnwrap(originalRecords.first { $0["id"] as? Int == completed.request.id })

        try mutateStoredPermissions { $0["https://wallet.example"] = "incompatible permissions" }
        let disconnected = try await removalSnapshot()
        XCTAssertNil(disconnected.ethereumAccount)
        for handle in [pending.handle, claimed.handle, selectionHandle] {
            let delivery = try await deliveredAuthority(handle)
            XCTAssertEqual((delivery.response["error"] as? [String: Any])?["code"] as? Int, 4100)
        }
        let recoveredRecords = try XCTUnwrap(storedProfile()["records"] as? [[String: Any]])
        let retainedCheckpoint = try XCTUnwrap(recoveredRecords.first { $0["id"] as? Int == broadcast.request.id })
        let retainedCompleted = try XCTUnwrap(recoveredRecords.first { $0["id"] as? Int == completed.request.id })
        XCTAssertTrue(NSDictionary(dictionary: originalCheckpoint).isEqual(to: retainedCheckpoint))
        XCTAssertTrue(NSDictionary(dictionary: originalCompleted).isEqual(to: retainedCompleted))

        let obsoleteGrant = ResponseToExtension(for: selection.request,
            payload: .result(.strings([account.normalizedAddress])),
            mutation: .accounts([.ethereum(address: account.normalizedAddress, chainId: "0x1")]),
            approvedAccounts: [account]).markingApprovalCommitted()
        _ = await bridge.complete(permit: selectionPermit, response: obsoleteGrant, authority: .ordinary)
        _ = await bridge.complete(permit: permit, response: response(for: claimed.request), authority: .ordinary)
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
        var writes = 0
        let unreadable = makeBridge(clock: { self.clock.now }, atomicWrite: { _, _ in
            writes += 1
            throw Failure.injectedWrite
        }, readData: { _ in throw Failure.injectedWrite })
        guard case .unavailable = await unreadable.configurationSnapshot(
            configurationKey: "https://wallet.example", profileIdentifier: nil
        ) else { return XCTFail("Read failures must not fabricate disconnected authority") }
        XCTAssertEqual(writes, 0)
        let unwritable = makeBridge(clock: { self.clock.now }, atomicWrite: { _, _ in
            writes += 1
            throw Failure.injectedWrite
        })
        guard case .unavailable = await unwritable.configurationSnapshot(
            configurationKey: "https://wallet.example", profileIdentifier: nil
        ) else { return XCTFail("Recovery must persist before returning disconnected authority") }
        XCTAssertGreaterThan(writes, 0)
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), corruptedData)
        let recovered = try await removalSnapshot()
        XCTAssertNil(recovered.ethereumAccount)
    }

    func testPermissionRecoveryRequiresSynchronizationAfterAmbiguousPublication() async throws {
        _ = try await grantAuthority(authorityTestAccount(), id: 64_030)
        try mutateStoredPermissions { $0["https://wallet.example"] = "incompatible permissions" }
        let corruptedData = try Data(contentsOf: defaultProfileURL)
        var synchronizations = 0
        for synchronizationSucceeds in [false, true] {
            try corruptedData.write(to: defaultProfileURL, options: .atomic)
            let observer = makeBridge(clock: { self.clock.now }, atomicWrite: { data, url in
                try ApprovalStoreTestPersistence.write(data, url)
                throw Failure.injectedWrite
            }, synchronizePublishedFile: { _ in
                synchronizations += 1
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
        XCTAssertEqual(synchronizations, 2)
    }

    func testPermissionRecoveryDoesNotMaskUnsupportedEnvelopeOrDamagedRequestHistory() async throws {
        _ = try await grantAuthority(authorityTestAccount(), id: 64_040)
        try mutateStoredPermissions { $0["https://wallet.example"] = "incompatible permissions" }
        let original = try storedProfile()
        var invalidProfiles = [[String: Any]]()
        for (key, value): (String, Any) in [
            ("schemaVersion", Int.max),
            ("workflowVersion", Int.max),
            ("profileIdentifier", UUID().uuidString),
            ("authorityEpoch", "not-an-epoch"),
        ] {
            var profile = original
            profile[key] = value
            invalidProfiles.append(profile)
        }
        var invalidRecord = original
        var records = try XCTUnwrap(invalidRecord["records"] as? [[String: Any]])
        records[0]["requestFingerprint"] = "invalid transaction history"
        invalidRecord["records"] = records
        invalidProfiles.append(invalidRecord)

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

    func testRevocationAbortsClaimBeforeSignatureCommitButRetainsBroadcastCheckpoint() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 60_020)
        let first = try await admittedSigning(account, id: 60_021)
        let firstClaim = try approvalClaim(await bridge.claim(handle: first.handle))
        XCTAssertEqual(firstClaim.executionDeadline, clock.now.addingTimeInterval(150))
        let firstPermit = try executionPermit(await bridge.begin(claim: firstClaim))
        let broadcast = try await admittedSigning(account, id: 60_022)
        let broadcastClaim = try approvalClaim(await bridge.claim(handle: broadcast.handle))
        let broadcastPermit = try executionPermit(await bridge.begin(claim: broadcastClaim))
        let recovery = ambiguousSubmissionResponse(for: broadcast.request, transactionHash: "0xpending").markingApprovalCommitted()
        let checkpoint = await bridge.prepareBroadcast(permit: broadcastPermit, recoveryResponse: recovery, authority: .ordinary)
        XCTAssertEqual(checkpoint, .persisted)
        guard case .snapshot(let current) = await bridge.configurationSnapshot(configurationKey: first.request.configurationKey, profileIdentifier: nil),
              case .revoked = await bridge.revoke(configurationKey: first.request.configurationKey,
                provider: .ethereum, attempt: attempt(for: 60_023), expected: current.version, profileIdentifier: nil) else {
            return XCTFail("Expected revocation")
        }
        let isCurrent = await bridge.authorityIsCurrent(handle: first.handle)
        XCTAssertFalse(isCurrent)
        _ = await bridge.complete(permit: firstPermit, response: response(for: first.request).markingApprovalCommitted(), authority: .ordinary)
        let firstDelivery = try await deliveredAuthority(first.handle)
        XCTAssertEqual((firstDelivery.response["error"] as? [String: Any])?["code"] as? Int, 4100)
        let completed = await bridge.complete(permit: broadcastPermit,
            response: response(for: broadcast.request).markingApprovalCommitted(), authority: .ordinary)
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
        let permit = try executionPermit(await bridge.begin(claim: claim))
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
                let completion = await bridge.complete(handle: handle, response: ResponseToExtension(
                    for: switching.request, payload: .result(.null), mutation: .ethereumChain(chainId)
                ))
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
        _ = await bridge.complete(permit: permit, response: response(for: signing.request), authority: .ordinary)
        let signingDelivery = try await deliveredAuthority(signing.handle)
        XCTAssertEqual((signingDelivery.response["error"] as? [String: Any])?["code"] as? Int, 4100)
    }

    func testECRecoverSurvivesUnrelatedWatermarkAndLocalGrantChanges() async throws {
        let first = try makeFixture(id: 60_110)
        let second = try makeFixture(id: 60_111)
        guard case .snapshot(let other) = await bridge.configurationSnapshot(
            configurationKey: "https://other.example", profileIdentifier: nil
        ), case .revoked = await bridge.revoke(configurationKey: "https://other.example", provider: .ethereum,
            attempt: attempt(for: 60_112), expected: other.version, profileIdentifier: nil),
           case .snapshot(let advanced) = await bridge.configurationSnapshot(
            configurationKey: first.request.configurationKey, profileIdentifier: nil
        ) else { return XCTFail("Expected unrelated authority advance") }
        XCTAssertGreaterThan(advanced.version.revisions.ethereum, first.ingress.authority.revisions.ethereum)
        let firstHandle = try accepted(await bridge.enqueue(ingress: first.ingress, profileIdentifier: nil)).handle
        let secondHandle = try accepted(await bridge.enqueue(ingress: second.ingress, profileIdentifier: nil)).handle
        let firstClaim = try approvalClaim(await bridge.claim(handle: firstHandle))
        let firstPermit = try executionPermit(await bridge.begin(claim: firstClaim))

        let grant = try await grantAuthority(authorityTestAccount(), id: 60_113)
        let secondClaim = try approvalClaim(await bridge.claim(handle: secondHandle))
        let secondPermit = try executionPermit(await bridge.begin(claim: secondClaim))
        guard case .snapshot(let granted) = await bridge.configurationSnapshot(
            configurationKey: grant.request.configurationKey, profileIdentifier: nil
        ), case .revoked = await bridge.revoke(configurationKey: grant.request.configurationKey, provider: .ethereum,
            attempt: attempt(for: 60_114), expected: granted.version, profileIdentifier: nil) else {
            return XCTFail("Expected local grant revocation")
        }
        for (fixture, handle, permit) in [(first, firstHandle, firstPermit), (second, secondHandle, secondPermit)] {
            let authorityCurrent = await bridge.authorityIsCurrent(handle: handle)
            XCTAssertTrue(authorityCurrent)
            let completion = await bridge.complete(permit: permit, response: response(for: fixture.request), authority: .ordinary)
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
        let fixture = try makeFixture(id: 60_030)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let delivered = try await recordNativeDelivery(handle: handle)
        XCTAssertEqual(delivered, .persisted)
        let claim = await claimDeliveredNativeExecution(in: bridge, handle: handle, approvedAt: clock.now)
        guard case .claimed(let nativeClaim) = claim else { return XCTFail("Native approval must execute directly") }
        XCTAssertEqual(nativeClaim.executionContext.executionDeadline, clock.now.addingTimeInterval(150))
        let competing = await claimDeliveredNativeExecution(in: bridge, handle: handle, approvedAt: clock.now)
        XCTAssertEqual(competing, .executing)
        clock.now = nativeClaim.executionContext.executionDeadline
        let expiredBegin = await bridge.begin(claim: nativeClaim.approvalClaim)
        XCTAssertEqual(expiredBegin, .ownershipLost)
        nativeClaim.approvalClaim.releaseLease()
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
        let result = await bridge.claimNativeExecution(
            handle: signing.handle, nativeDeliveryNonce: receipt.nativeDeliveryNonce,
            runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier, approvedAt: approvedAt
        )
        XCTAssertEqual(result, .responded)
        let response = try await deliveredAuthority(signing.handle)
        XCTAssertEqual((response.response["error"] as? [String: Any])?["code"] as? Int, 4100)
    }

    func testConcurrentNativeClaimersPersistOnlyOneAtomicTransition() async throws {
        let fixture = try makeFixture(id: 60_031)
        let admission = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil))
        let owner = storedRequestNativeOwner()
        let delivered = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle, nativeDeliveryNonce: admission.nativeDeliveryNonce, owner: owner
        )
        XCTAssertEqual(delivered, .persisted)
        let now = clock.now
        var writes = 0
        let atomicWrite: (Data, URL) throws -> Void = { data, url in
            writes += 1
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
        async let firstResult = first.claimNativeExecution(
            handle: admission.handle, nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: owner.runtimeInstanceIdentifier, approvedAt: now
        )
        async let secondResult = second.claimNativeExecution(
            handle: admission.handle, nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: owner.runtimeInstanceIdentifier, approvedAt: now
        )
        let results = await [firstResult, secondResult]
        let claims = results.compactMap { result -> ExtensionBridge.NativeExecutionClaim? in
            guard case .claimed(let claim) = result else { return nil }
            return claim
        }
        defer { claims.forEach { $0.approvalClaim.releaseLease() } }
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(results.filter { $0 == .executing }.count, 1)
        XCTAssertEqual(writes, 1)
        guard case .found(let snapshot) = await bridge.load(handle: admission.handle) else {
            return XCTFail("Expected persisted execution")
        }
        XCTAssertTrue(snapshot.hasActiveExecution)
        XCTAssertFalse(snapshot.isQueuedForNativeApproval)
        XCTAssertEqual(snapshot.nativeApproval?.approvedAt, now)
        XCTAssertEqual(snapshot.nativeExecutionContext, claims.first?.executionContext)
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
        let released = await bridge.release(claim: claim)
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
        raw["body"] = ["address": "", "padding": ""]
        let emptySize = try XCTUnwrap(ExtensionBridge.payloadData(raw, options: [.sortedKeys])).count
        let paddingCount = ExtensionBridge.maximumPayloadBytes - emptySize
        raw["body"] = ["address": "", "padding": String(repeating: "x", count: paddingCount)]
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
        let rejectingWriter = makeBridge(clock: { self.clock.now }, atomicWrite: { _, _ in
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

        raw["body"] = ["address": "", "padding": String(repeating: "x", count: paddingCount - 1)]
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
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 60_080)
        let fixture = try makeFixture(id: 60_081, admissionDeadline: clock.now.addingTimeInterval(1))
        let admission = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil))
        let owner = storedRequestNativeOwner()
        let receipt = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle, nativeDeliveryNonce: admission.nativeDeliveryNonce, owner: owner
        )
        XCTAssertEqual(receipt, .persisted)
        clock.now = fixture.request.admissionDeadline.addingTimeInterval(-0.01)
        let approvedAt = clock.now
        var writes = 0
        let claimingWriter = makeBridge(
            clock: { self.clock.now },
            atomicWrite: { data, url in
                writes += 1
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
                self.clock.now = fixture.request.admissionDeadline.addingTimeInterval(0.01)
                return data
            }
        )
        let result = await claimingWriter.claimNativeExecution(
            handle: admission.handle, nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: owner.runtimeInstanceIdentifier, approvedAt: approvedAt
        )
        XCTAssertEqual(result, .ownershipLost)
        XCTAssertEqual(writes, 1)
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
        var writes = 0
        let tested = makeBridge(clock: { self.clock.now }, atomicWrite: { data, url in
            writes += 1
            try ApprovalStoreTestPersistence.write(data, url)
        })
        guard case .snapshot(let before) = await tested.configurationSnapshot(configurationKey: key, profileIdentifier: nil) else {
            return XCTFail("Expected valid profile at the authority byte limit")
        }
        guard case .unavailable = await tested.revoke(configurationKey: key, provider: .ethereum,
            attempt: attempt(for: 61_400), expected: before.version, profileIdentifier: nil) else {
            return XCTFail("An oversized authority mutation must not persist")
        }
        XCTAssertEqual(writes, 0)
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
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(revoked.version.revisions.ethereum, 401)
        XCTAssertEqual(readable.version, revoked.version)
    }

    func testWalletSourceMutationSerializesPreparationAndWritesWithoutRevocation() throws {
        let store = removalStore()
        let competing = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            crossProcessLockTimeoutNanoseconds: 0, crossProcessLockPollNanoseconds: 0
        ))
        let competingLock = CrossProcessFileLock(fileURL: rootURL.appendingPathComponent("bridge-v8.lock"))
        var source = ["original"]
        var competingPreparations = 0
        var events = [String]()
        let result = try store.perform(preparing: {
            events.append("prepare")
            XCTAssertFalse(try competingLock.tryAcquire())
            XCTAssertThrowsError(try competing.perform(preparing: {
                competingPreparations += 1
                return PreparedWalletSourceMutation(payload: source + ["competing"], authorityRemovals: [])
            }, beforeCommit: {}, commit: { source = $0 }))
            XCTAssertEqual(competingPreparations, 0)
            return PreparedWalletSourceMutation(payload: source + ["added"], authorityRemovals: [.accounts([])])
        }, beforeCommit: {
            events.append("invalidate")
            XCTAssertFalse(try competingLock.tryAcquire())
            XCTAssertEqual(source, ["original"])
        }, commit: { prepared in
            events.append("commit")
            XCTAssertFalse(try competingLock.tryAcquire())
            source = prepared
            return source.count
        })
        XCTAssertEqual(result, 2)
        XCTAssertEqual(events, ["prepare", "invalidate", "commit"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("profiles-v8").path))
        try competing.perform(preparing: {
            competingPreparations += 1
            XCTAssertEqual(source, ["original", "added"])
            return PreparedWalletSourceMutation(payload: source + ["competing"], authorityRemovals: [])
        }, beforeCommit: {}, commit: { source = $0 })
        XCTAssertEqual(competingPreparations, 1)
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
        let competingLock = CrossProcessFileLock(fileURL: rootURL.appendingPathComponent("bridge-v8.lock"))
        var sourceWrites = 0
        XCTAssertThrowsError(try store.perform(preparing: {
            PreparedWalletSourceMutation(payload: (), authorityRemovals: [.accounts([account])])
        }, beforeCommit: {
            XCTAssertFalse(try competingLock.tryAcquire())
            throw Failure.injectedWrite
        }, commit: { _ in sourceWrites += 1 }))
        let after = try await removalSnapshot()
        XCTAssertEqual(after.ethereumAccount, account)
        XCTAssertEqual(after.version, before.version)
        XCTAssertEqual(sourceWrites, 0)
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
        let competingLock = CrossProcessFileLock(fileURL: rootURL.appendingPathComponent("bridge-v8.lock"))
        var sourceWrites = 0
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
            sourceWrites += 1
        })
        let after = try await removalSnapshot()
        XCTAssertEqual(sourceWrites, 1)
        XCTAssertNil(after.ethereumAccount)
        XCTAssertNil(after.solanaAccount)
        XCTAssertTrue(try competingLock.tryAcquire())
        competingLock.release()
    }

    func testScopedRevocationFailurePreventsSourceWriteAndReleasesTransactionLock() async throws {
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 62_983)
        let store = removalStore(atomicWrite: { _, _ in throw Failure.injectedWrite })
        var preparations = 0
        var writes = 0
        XCTAssertThrowsError(try store.perform(preparing: {
            preparations += 1
            return PreparedWalletSourceMutation(payload: (), authorityRemovals: [.accounts([account])])
        }, beforeCommit: {}, commit: { _ in
            writes += 1
        }))
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(writes, 0)
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
        var sourceMutations = 0
        try store.withRevokedWalletAuthority(matching: .accounts([account])) {
            sourceMutations += 1
            let competingLock = CrossProcessFileLock(fileURL: rootURL.appendingPathComponent("bridge-v8.lock"))
            XCTAssertFalse(try competingLock.tryAcquire())
            competingLock.release()
        }
        XCTAssertEqual(sourceMutations, 1)
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

    func testWalletRemovalFencesSigningAndUncommittedSelectionsButKeepsBroadcastAndCompletedResults() async throws {
        let account = authorityTestAccount()
        let grant = try await grantAuthority(account, id: 63_010)
        let pending = try await admittedSigning(account, id: 63_011)
        let claimed = try await admittedSigning(account, id: 63_012)
        let claim = try approvalClaim(await bridge.claim(handle: claimed.handle))
        let permit = try executionPermit(await bridge.begin(claim: claim))
        let broadcast = try await admittedSigning(account, id: 63_013)
        let broadcastClaim = try approvalClaim(await bridge.claim(handle: broadcast.handle))
        let broadcastPermit = try executionPermit(await bridge.begin(claim: broadcastClaim))
        let checkpoint = await bridge.prepareBroadcast(permit: broadcastPermit,
            recoveryResponse: ambiguousSubmissionResponse(for: broadcast.request, transactionHash: "0xpending").markingApprovalCommitted(),
            authority: .ordinary)
        XCTAssertEqual(checkpoint, .persisted)
        let selection = try makeFixture(id: 63_014, name: "requestAccounts", host: "selection.example")
        let selectionHandle = try accepted(await bridge.enqueue(ingress: selection.ingress, profileIdentifier: nil)).handle
        let selectionClaim = try approvalClaim(await bridge.claim(handle: selectionHandle))
        let selectionPermit = try executionPermit(await bridge.begin(claim: selectionClaim))
        let native = try makeFixture(id: 63_015, name: "requestAccounts", host: "native.example")
        let nativeHandle = try accepted(await bridge.enqueue(ingress: native.ingress, profileIdentifier: nil)).handle
        _ = try await recordNativeDelivery(handle: nativeHandle)
        guard case .claimed(let nativeClaim) = await claimDeliveredNativeExecution(
            in: bridge, handle: nativeHandle, approvedAt: clock.now
        ) else { return XCTFail("Expected native claim") }
        defer { nativeClaim.approvalClaim.releaseLease() }
        let manual = try makeManualFixture(id: 63_016, enqueueAttempt: attempt(for: 63_016), latestConfigurations: [],
            host: "manual.example", configurationKey: "https://manual.example")
        let manualHandle = try accepted(await bridge.enqueue(ingress: manual.ingress, profileIdentifier: nil)).handle
        let solanaTemplate = try makeFixture(id: 63_017, host: "solana.example")
        var solanaRaw = try XCTUnwrap(JSONSerialization.jsonObject(with: solanaTemplate.ingress.canonicalData) as? [String: Any])
        solanaRaw["name"] = "connect"
        solanaRaw["provider"] = "solana"
        solanaRaw["body"] = ["publicKey": ""]
        let solana = try authorityFixture(solanaRaw)
        let solanaHandle = try accepted(await bridge.enqueue(ingress: solana.ingress, profileIdentifier: nil)).handle

        try removalStore().withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) {}
        for handle in [pending.handle, claimed.handle, selectionHandle, nativeHandle, manualHandle, solanaHandle] {
            let delivery = try await deliveredAuthority(handle)
            XCTAssertEqual((delivery.response["error"] as? [String: Any])?["code"] as? Int, 4100)
        }
        let obsoleteGrant = ResponseToExtension(for: selection.request, payload: .result(.strings([account.normalizedAddress])),
            mutation: .accounts([.ethereum(address: account.normalizedAddress, chainId: "0x1")]), approvedAccounts: [account])
        _ = await bridge.complete(permit: selectionPermit, response: obsoleteGrant, authority: .ordinary)
        _ = await bridge.complete(permit: permit, response: response(for: claimed.request), authority: .ordinary)
        let selectionState = try await removalSnapshot(host: "selection.example")
        XCTAssertNil(selectionState.ethereumAccount)
        let broadcastCompletion = await bridge.complete(permit: broadcastPermit,
            response: response(for: broadcast.request).markingApprovalCommitted(), authority: .ordinary)
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
        solanaRaw["body"] = ["publicKey": solana.normalizedAddress]
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
        try removalStore().withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) {}
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

    func testWalletRemovalRunsWithoutProfilesAndRejectsUnsafeOrCorruptProfilesBeforeSourceMutation() async throws {
        var sourceMutations = 0
        let result = try removalStore().withRevokedWalletAuthority(matching: .wallet(id: "wallet")) {
            sourceMutations += 1
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("profiles-v8").path))
        try Data([1]).write(to: rootURL.appendingPathComponent("profiles-v8"))
        XCTAssertThrowsError(try removalStore().withRevokedWalletAuthority(matching: .wallet(id: "wallet")) {
            sourceMutations += 1
        })
        try FileManager.default.removeItem(at: rootURL.appendingPathComponent("profiles-v8"))
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 63_030)
        try Data([1]).write(to: profileURL(UUID()))
        XCTAssertThrowsError(try removalStore().withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) {
            sourceMutations += 1
        })
        XCTAssertEqual(sourceMutations, 1)
        let unchanged = try await removalSnapshot()
        XCTAssertEqual(unchanged.ethereumAccount, account)
    }

    func testWalletRemovalPersistenceFailureBlocksSourceAndRetriesPartialCleanup() async throws {
        let account = authorityTestAccount()
        let secondProfile = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        _ = try await grantAuthority(account, id: 63_040)
        _ = try await grantAuthority(account, id: 63_041, profileIdentifier: secondProfile)
        var sourceMutations = 0
        var writes = 0
        let failingStore = removalStore(atomicWrite: { data, url in
            writes += 1
            if writes == 2 { throw Failure.injectedWrite }
            try ApprovalStoreTestPersistence.write(data, url)
        })
        XCTAssertThrowsError(try failingStore.withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) {
            sourceMutations += 1
        })
        XCTAssertEqual(sourceMutations, 0)
        let partiallyRemoved = try await removalSnapshot(profileIdentifier: secondProfile)
        let stillGranted = try await removalSnapshot()
        XCTAssertNil(partiallyRemoved.ethereumAccount)
        XCTAssertEqual(stillGranted.ethereumAccount, account)
        try removalStore().withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) { sourceMutations += 1 }
        let retried = try await removalSnapshot(profileIdentifier: secondProfile)
        let fullyRemoved = try await removalSnapshot()
        XCTAssertEqual(sourceMutations, 1)
        XCTAssertEqual(retried.version, partiallyRemoved.version)
        XCTAssertNil(fullyRemoved.ethereumAccount)
    }

    func testWalletRemovalSynchronizesUnchangedProfilesAndKeepsRevocationWhenSourceFails() async throws {
        _ = try authorityVersion("https://empty.example")
        var sourceMutations = 0
        let failingStore = removalStore(synchronizePublishedFile: { _ in throw Failure.injectedWrite })
        XCTAssertThrowsError(try failingStore.withRevokedWalletAuthority(matching: .wallet(id: "absent-wallet")) {
            sourceMutations += 1
        })
        XCTAssertEqual(sourceMutations, 0)
        let account = authorityTestAccount()
        _ = try await grantAuthority(account, id: 63_050)
        XCTAssertThrowsError(try removalStore().withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) {
            sourceMutations += 1
            throw Failure.injectedWrite
        })
        let removed = try await removalSnapshot()
        XCTAssertNil(removed.ethereumAccount)
        try removalStore().withRevokedWalletAuthority(matching: .wallet(id: account.walletID)) { sourceMutations += 1 }
        let retried = try await removalSnapshot()
        XCTAssertEqual(sourceMutations, 2)
        XCTAssertEqual(retried.version, removed.version)
    }

    private func removalStore(
        atomicWrite: ExtensionRequestFileStore.AtomicWrite? = ApprovalStoreTestPersistence.write,
        synchronizePublishedFile: ExtensionRequestFileStore.SynchronizePublishedFile? = nil
    ) -> ExtensionRequestFileStore {
        ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { self.clock.now }, atomicWrite: atomicWrite, synchronizePublishedFile: synchronizePublishedFile
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
        raw["body"] = account.coin == .ethereum ? ["address": "", "chainId": chainId] : ["publicKey": ""]
        let connection = try authorityFixture(raw)
        let handle = try accepted(await bridge.enqueue(ingress: connection.ingress, profileIdentifier: profileIdentifier)).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        let permit = try executionPermit(await bridge.begin(claim: claim))
        let result: ResponseToExtension.Result = account.coin == .ethereum
            ? .strings([account.normalizedAddress]) : .solanaPublicKey(account.normalizedAddress)
        let update: ResponseToExtension.AccountUpdate = account.coin == .ethereum
            ? .ethereum(address: account.normalizedAddress, chainId: chainId) : .solana(publicKey: account.normalizedAddress)
        let response = ResponseToExtension(for: connection.request, payload: .result(result),
            mutation: .accounts([update]), approvedAccounts: [account]).markingApprovalCommitted()
        let completion = await bridge.complete(permit: permit, response: response, authority: .ordinary)
        XCTAssertEqual(completion, .persisted)
        return (connection.request, handle)
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

        let switches = await bridge.listManualSwitchRequests(profileIdentifier: nil)
        XCTAssertEqual(response, .missing)

        XCTAssertEqual(switches, .available([]))
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
        claim.releaseLease()
        clock.now = manual.request.admissionDeadline.addingTimeInterval(1)
        let original = try Data(contentsOf: defaultProfileURL)
        let originalPaths = try FileManager.default.subpathsOfDirectory(atPath: rootURL.path).sorted()
        let observer = makeBridge(
            clock: { self.clock.now },
            atomicWrite: { _, _ in XCTFail("Observation wrote storage"); throw Failure.injectedWrite },
            synchronizePublishedFile: { _ in XCTFail("Observation synchronized storage"); throw Failure.injectedWrite }
        )
        let manualStatus = await observer.responseStatus(
            handle: manualHandle, configurationKey: manual.request.configurationKey, manualOnly: true
        )

        let nonManual = await observer.responseStatus(
            handle: ordinaryHandle, configurationKey: ordinary.request.configurationKey, manualOnly: true
        )
        let switches = try manualSwitchRequests(await observer.listManualSwitchRequests(profileIdentifier: nil))
        XCTAssertEqual(manualStatus, .pending)

        XCTAssertEqual(nonManual, .missing)
        XCTAssertEqual(switches.map(\.state), [.pending])
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: rootURL.path).sorted(), originalPaths)
    }

    func testReadyStatusDoesNotSynchronizeOrAcknowledgeResponse() async throws {
        let fixture = try makeFixture(id: 952)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let completed = await bridge.complete(handle: handle, response: response(for: fixture.request))
        XCTAssertEqual(completed, .persisted)
        let original = try Data(contentsOf: defaultProfileURL)
        var synchronizations = 0
        let observer = makeBridge(
            clock: { self.clock.now },
            atomicWrite: { _, _ in XCTFail("Observation wrote storage"); throw Failure.injectedWrite },
            synchronizePublishedFile: { _ in synchronizations += 1; throw Failure.injectedWrite }
        )
        let status = await observer.responseStatus(handle: handle, configurationKey: fixture.request.configurationKey)

        let wrongIdentity = await observer.responseStatus(handle: handle, configurationKey: "https://other.example")
        XCTAssertEqual(status, .ready)

        XCTAssertEqual(wrongIdentity, .missing)
        XCTAssertEqual(synchronizations, 0)
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original)
        guard case .unavailable = await observer.prepareResponseDelivery(
            id: handle.id, configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken, profileIdentifier: nil
        ) else { return XCTFail("Delivery must still require its durability barrier") }
        XCTAssertEqual(synchronizations, 1)
    }

    func testObservationalReadsRejectMissingAndUnsafeExistingStoreLocks() async throws {
        let fixture = try makeFixture(id: 953)
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let lockURL = rootURL.appendingPathComponent("bridge-v8.lock")
        try FileManager.default.removeItem(at: lockURL)
        let missingLock = await bridge.responseStatus(handle: handle, configurationKey: fixture.request.configurationKey)
        XCTAssertEqual(missingLock, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: defaultProfileURL)
        let original = try Data(contentsOf: defaultProfileURL)

        let unsafeDiscovery = await bridge.listManualSwitchRequests(profileIdentifier: nil)

        XCTAssertEqual(unsafeDiscovery, .unavailable)
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original)
    }

    func testObservationalReadsPreserveFutureDatesAndExpiredCompletedResponses() async throws {
        let fixture = try makeManualFixture(
            id: 958, enqueueAttempt: attempt(for: 958), latestConfigurations: []
        )
        let handle = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)).handle
        let completed = await bridge.complete(handle: handle, response: response(for: fixture.request))
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
            clock: { self.clock.now },
            atomicWrite: { _, _ in XCTFail("Observation wrote storage"); throw Failure.injectedWrite },
            synchronizePublishedFile: { _ in XCTFail("Observation synchronized storage"); throw Failure.injectedWrite }
        )
        for observedAt in [clock.now, future.addingTimeInterval(ExtensionBridge.responseExpiry + 1)] {
            clock.now = observedAt
            let status = await observer.responseStatus(
                handle: handle, configurationKey: fixture.request.configurationKey, manualOnly: true
            )
            let switches = try manualSwitchRequests(await observer.listManualSwitchRequests(profileIdentifier: nil))
            XCTAssertEqual(status, .ready)
            XCTAssertEqual(switches.map(\.state), [.completed])
            XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original)
        }
        await bridge.performMaintenance(profileIdentifier: nil)
        let retired = await observer.responseStatus(handle: handle, configurationKey: fixture.request.configurationKey)
        XCTAssertEqual(retired, .missing)
    }

    func testObservationalReadsDoNotRecoverOrSynchronizeBroadcastCheckpoint() async throws {
        let execution = try await makeExecutableNativePermit(id: 959)
        let checkpoint = await bridge.prepareBroadcast(
            permit: execution.permit, recoveryResponse: response(for: execution.request),
            authority: .native(execution.context)
        )
        XCTAssertEqual(checkpoint, .persisted)
        execution.permit.releaseLease()

        let original = try Data(contentsOf: defaultProfileURL)
        let originalPaths = try FileManager.default.subpathsOfDirectory(atPath: rootURL.path).sorted()
        let observer = makeBridge(
            clock: { self.clock.now },
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
            at: rootURL.appendingPathComponent("bridge-v8.lock"),
            readyURL: rootURL.appendingPathComponent("observation-holder-ready")
        ) {
            let started = ContinuousClock.now
            let response = await self.bridge.responseStatus(handle: handle, configurationKey: fixture.request.configurationKey)

            let switches = await self.bridge.listManualSwitchRequests(profileIdentifier: nil)
            XCTAssertEqual(response, .unavailable)

            XCTAssertEqual(switches, .unavailable)
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
            "attemptID": UUID().uuidString.lowercased(), "revisions": ["ethereum": 0, "solana": 0],
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
        var unavailable = true
        let writer = makeBridge(clock: { self.clock.now }, readData: { url in
            if unavailable { throw CocoaError(.fileReadUnknown) }
            return try ExtensionRequestFileStore.defaultReadData(url)
        })

        let failed = await writer.complete(handle: handle, response: response(for: fixture.request))
        XCTAssertEqual(failed, .retryablePersistenceFailure)
        unavailable = false
        let retried = await writer.complete(handle: handle, response: response(for: fixture.request))
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
        XCTAssertEqual(profile["schemaVersion"] as? Int, 8)
        _ = await bridge.list(profileIdentifier: nil)
        for (url, data) in preservedFiles {
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultProfileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL
            .appendingPathComponent("operation-locks-v8", isDirectory: true)
            .path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL
            .appendingPathComponent(
                "native-execution-fences-v7",
                isDirectory: true
            ).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL
            .appendingPathComponent("bridge-v8.lock").path))
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

    func testV8OrdinaryStatesRoundTripWithoutChangingRequestOrResponseBytes()
        async throws {
        let fixture = try makeFixture(id: 85)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        XCTAssertEqual(
            try Data(contentsOf: defaultProfileURL).prefix(8),
            Data("bplist00".utf8)
        )
        XCTAssertEqual(
            try firstStoredState("pending")["request"] as? Data,
            fixture.ingress.canonicalData
        )
        bridge = makeBridge(clock: { self.clock.now })
        guard case .found(let pending) = await bridge.load(handle: handle) else {
            return XCTFail("Expected pending request after restart")
        }
        XCTAssertEqual(pending.phase, .queued)

        let claim = try approvalClaim(await bridge.claim(handle: handle))
        XCTAssertEqual(
            try firstStoredState("claimed")["request"] as? Data,
            fixture.ingress.canonicalData
        )
        bridge = makeBridge(clock: { self.clock.now })
        guard case .found(let claimed) = await bridge.load(handle: handle) else {
            return XCTFail("Expected held claim after restart")
        }
        XCTAssertEqual(claimed.phase, .approving)
        XCTAssertNil(claimed.nativeApproval)
        XCTAssertNil(claimed.nativeExecutionContext)

        let permit = try executionPermit(await bridge.begin(claim: claim))
        let recovery = ambiguousSubmissionResponse(
            for: fixture.request,
            transactionHash: "0x1234"
        ).markingApprovalCommitted()
        let checkpoint = await bridge.prepareBroadcast(
            permit: permit,
            recoveryResponse: recovery,
            authority: .ordinary
        )
        XCTAssertEqual(checkpoint, .persisted)
        let broadcast = try firstStoredState("broadcastPrepared")
        XCTAssertEqual(broadcast["request"] as? Data, fixture.ingress.canonicalData)
        XCTAssertEqual(
            broadcast["recoveryResponse"] as? Data,
            ExtensionBridge.payloadData(recovery.json, options: [.sortedKeys])
        )
        bridge = makeBridge(clock: { self.clock.now })
        guard case .found(let prepared) = await bridge.load(handle: handle) else {
            return XCTFail("Expected held broadcast after restart")
        }
        XCTAssertEqual(prepared.phase, .approving)

        let response = response(for: fixture.request).markingApprovalCommitted()
        let completion = await bridge.complete(
            permit: permit,
            response: response,
            authority: .ordinary
        )
        XCTAssertEqual(completion, .persisted)
        let completed = try firstStoredState("completed")
        XCTAssertEqual(Set(completed.keys), ["since", "response", "acknowledged"])
        XCTAssertEqual(completed["acknowledged"] as? Bool, false)
        XCTAssertEqual(
            completed["response"] as? Data,
            ExtensionBridge.payloadData(response.json, options: [.sortedKeys])
        )
        bridge = makeBridge(clock: { self.clock.now })
        guard case .found(let terminal) = await bridge.load(handle: handle) else {
            return XCTFail("Expected completed response after restart")
        }
        XCTAssertEqual(terminal.phase, .responded)
        XCTAssertNil(terminal.request)
        XCTAssertNil(terminal.nativeApproval)
        XCTAssertNil(terminal.nativeDeliveryReceipt)
        XCTAssertNil(terminal.nativeExecutionContext)
    }

    func testValidatedRequestsAreParsedOnceForSnapshotsAndManualSwitchDiscovery() throws {
        let parsing = RequestParseRecorder()
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { self.clock.now },
            parseRequest: parsing.parse
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
        XCTAssertEqual(parsing.takeIDs(), [])
        let manualHandle = try accepted(store.enqueue(
            ingress: manual.ingress,
            profileIdentifier: nil
        )).handle
        XCTAssertEqual(parsing.takeIDs(), [ordinary.request.id, manual.request.id])

        guard case .available(let snapshots) = store.list(profileIdentifier: nil) else {
            return XCTFail("Expected validated snapshots")
        }
        XCTAssertEqual(snapshots[ordinaryHandle]?.request?.id, ordinary.request.id)
        XCTAssertEqual(snapshots[manualHandle]?.request?.id, manual.request.id)
        XCTAssertEqual(parsing.takeIDs(), [ordinary.request.id, manual.request.id])

        guard case .found(let ordinarySnapshot) = store.load(handle: ordinaryHandle) else {
            return XCTFail("Expected ordinary snapshot")
        }
        XCTAssertEqual(ordinarySnapshot.request?.id, ordinary.request.id)
        XCTAssertEqual(parsing.takeIDs(), [ordinary.request.id, manual.request.id])

        let page = try manualSwitchRequests(store.listManualSwitchRequests(
            profileIdentifier: nil
        ))
        XCTAssertEqual(page.map(\.handle), [manualHandle])
        XCTAssertEqual(parsing.takeIDs(), [ordinary.request.id, manual.request.id])
        guard case .found(let manualSnapshot) = store.loadManualSwitch(
            handle: manualHandle,
            configurationKey: manual.request.configurationKey
        ) else { return XCTFail("Expected manual switch snapshot") }
        XCTAssertEqual(manualSnapshot.request?.id, manual.request.id)
        XCTAssertEqual(parsing.takeIDs(), [ordinary.request.id, manual.request.id])

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
        XCTAssertEqual(parsing.takeIDs(), [ordinary.request.id, manual.request.id])
    }

    func testValidatedRequestsAreRebuiltAfterAnotherStoreChangesTheProfile() throws {
        let parsing = RequestParseRecorder()
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { self.clock.now },
            parseRequest: parsing.parse
        ))
        let otherStore = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { self.clock.now }
        ))
        let first = try makeFixture(id: 904)
        let handle = try accepted(store.enqueue(
            ingress: first.ingress,
            profileIdentifier: nil
        )).handle
        guard case .found = store.load(handle: handle) else {
            return XCTFail("Expected initial request")
        }
        XCTAssertEqual(parsing.takeIDs(), [first.request.id])
        guard case .found = store.load(handle: handle) else {
            return XCTFail("Expected a fresh read of the same request")
        }
        XCTAssertEqual(parsing.takeIDs(), [first.request.id])

        let second = try makeFixture(id: 905)
        _ = try accepted(otherStore.enqueue(ingress: second.ingress, profileIdentifier: nil))
        XCTAssertEqual(otherStore.complete(
            handle: handle,
            response: response(for: first.request)
        ), .persisted)
        guard case .found(let completed) = store.load(handle: handle) else {
            return XCTFail("Expected the other store's completion")
        }
        XCTAssertEqual(completed.phase, .responded)
        XCTAssertNil(completed.request)
        XCTAssertEqual(parsing.takeIDs(), [second.request.id])

        let persisted = try Data(contentsOf: defaultProfileURL)
        try Data("corrupt profile".utf8).write(to: defaultProfileURL)
        guard case .unavailable = store.load(handle: handle) else {
            return XCTFail("Expected corruption to be observed on the next operation")
        }
        XCTAssertEqual(parsing.takeIDs(), [])
        try persisted.write(to: defaultProfileURL)
        guard case .found = store.load(handle: handle) else {
            return XCTFail("Expected a fresh read after the profile is restored")
        }
        XCTAssertEqual(parsing.takeIDs(), [second.request.id])
        try FileManager.default.removeItem(at: defaultProfileURL)
        guard case .missing = store.load(handle: handle) else {
            return XCTFail("Expected removal to be observed on the next operation")
        }
        XCTAssertEqual(parsing.takeIDs(), [])
    }

    func testValidatedRequestsSurviveStateTransitionsWithoutReencodingStoredBytes() throws {
        let parsing = RequestParseRecorder()
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { self.clock.now },
            parseRequest: parsing.parse
        ))
        let fixture = try makeFixture(id: 906)
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
        XCTAssertEqual(parsing.takeIDs(), [])
        let initialClaim = try approvalClaim(store.claim(handle: handle))
        XCTAssertEqual(parsing.takeIDs(), [fixture.request.id])
        XCTAssertEqual(try firstStoredState("claimed")["request"] as? Data, originalData)
        XCTAssertEqual(store.release(claim: initialClaim), .persisted)
        XCTAssertEqual(parsing.takeIDs(), [fixture.request.id])
        XCTAssertEqual(try firstStoredState("pending")["request"] as? Data, originalData)

        let rollbackClaim = try approvalClaim(store.claim(handle: handle))
        let rollbackPermit = try executionPermit(store.begin(claim: rollbackClaim))
        XCTAssertEqual(parsing.takeIDs(), [fixture.request.id, fixture.request.id])
        XCTAssertEqual(store.rollback(permit: rollbackPermit), .persisted)
        XCTAssertEqual(parsing.takeIDs(), [fixture.request.id])
        XCTAssertEqual(try firstStoredState("pending")["request"] as? Data, originalData)

        let claim = try approvalClaim(store.claim(handle: handle))
        let permit = try executionPermit(store.begin(claim: claim))
        XCTAssertEqual(parsing.takeIDs(), [fixture.request.id, fixture.request.id])
        let recovery = ambiguousSubmissionResponse(for: fixture.request, transactionHash: "0x1234")
        XCTAssertEqual(store.prepareBroadcast(
            permit: permit,
            recoveryResponse: recovery,
            authority: .ordinary
        ), .persisted)
        XCTAssertEqual(parsing.takeIDs(), [fixture.request.id])
        XCTAssertEqual(try firstStoredState("broadcastPrepared")["request"] as? Data, originalData)
        XCTAssertEqual(store.complete(
            permit: permit,
            response: response(for: fixture.request),
            authority: .ordinary
        ), .persisted)
        XCTAssertEqual(parsing.takeIDs(), [fixture.request.id])
        guard case .found(let completed) = store.load(handle: handle) else {
            return XCTFail("Expected completed snapshot")
        }
        XCTAssertNil(completed.request)
        XCTAssertEqual(parsing.takeIDs(), [])
    }

    func testValidatedRequestsAreReusedForExpiryAndAbandonedExecutionRecovery() throws {
        let parsing = RequestParseRecorder()
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { self.clock.now },
            parseRequest: parsing.parse
        ))
        for (index, state) in ["pending", "claimed", "broadcastPrepared"].enumerated() {
            let fixture = try makeFixture(id: 907 + index)
            let handle = try accepted(store.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: nil
            )).handle
            if state != "pending" {
                let claim = try approvalClaim(store.claim(handle: handle))
                if state == "broadcastPrepared" {
                    let permit = try executionPermit(store.begin(claim: claim))
                    let recovery = ambiguousSubmissionResponse(
                        for: fixture.request,
                        transactionHash: "0x1234"
                    )
                    XCTAssertEqual(store.prepareBroadcast(
                        permit: permit,
                        recoveryResponse: recovery,
                        authority: .ordinary
                    ), .persisted)
                    permit.releaseLease()
                } else {
                    claim.releaseLease()
                }
            }
            _ = parsing.takeIDs()
            clock.now.addTimeInterval(ExtensionBridge.requestTTL)
            guard case .found(let recovered) = store.load(handle: handle) else {
                return XCTFail("Expected recovery from \(state)")
            }
            XCTAssertEqual(recovered.phase, .responded)
            XCTAssertNil(recovered.request)
            XCTAssertEqual(parsing.takeIDs(), [fixture.request.id])
            let terminal = try responseJSON(store.prepareResponseDelivery(
                handle: handle,
                configurationKey: fixture.request.configurationKey
            ))
            let expected = state == "broadcastPrepared"
                ? ambiguousSubmissionResponse(for: fixture.request, transactionHash: "0x1234")
                : ResponseToExtension(for: fixture.request, payload: .error(.userRejected))
            XCTAssertEqual(terminal as NSDictionary, expected.json as NSDictionary)
            XCTAssertEqual(parsing.takeIDs(), [])
        }
    }

    func testValidatedRequestsAreReparsedAfterFailedAndAmbiguousWrites() throws {
        let parsing = RequestParseRecorder()
        var failBeforeWrite = false
        var failAfterWrite = false
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            clock: { self.clock.now },
            atomicWrite: { data, url in
                if failBeforeWrite { throw Failure.injectedWrite }
                try ApprovalStoreTestPersistence.write(data, url)
                if failAfterWrite { throw Failure.injectedWrite }
            },
            parseRequest: parsing.parse
        ))
        let fixture = try makeFixture(id: 910)
        let handle = try accepted(store.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        failBeforeWrite = true
        XCTAssertEqual(store.reject(handle: handle), .retryablePersistenceFailure)
        XCTAssertEqual(parsing.takeIDs(), [fixture.request.id])
        failBeforeWrite = false
        guard case .found(let pending) = store.load(handle: handle) else {
            return XCTFail("Expected the persisted pending request after a failed write")
        }
        XCTAssertEqual(pending.phase, .queued)
        XCTAssertEqual(pending.request?.id, fixture.request.id)
        XCTAssertEqual(parsing.takeIDs(), [fixture.request.id])

        failAfterWrite = true
        XCTAssertEqual(store.complete(
            handle: handle,
            response: response(for: fixture.request)
        ), .persisted)
        XCTAssertEqual(parsing.takeIDs(), [fixture.request.id])
        failAfterWrite = false
        guard case .found(let completed) = store.load(handle: handle) else {
            return XCTFail("Expected completion after exact read-back recovery")
        }
        XCTAssertNil(completed.request)
        XCTAssertEqual(parsing.takeIDs(), [])
    }

    func testLostEnqueueReplyDeduplicatesTheExactAttempt() async throws {
        final class WriteControl {
            var shouldThrow = true
            func write(_ data: Data, to url: URL) throws {
                try ApprovalStoreTestPersistence.write(data, url)
                if shouldThrow, url.pathExtension == "state" {
                    shouldThrow = false
                    throw Failure.injectedWrite
                }
            }
        }
        let writes = WriteControl()
        bridge = makeBridge(
            clock: { self.clock.now },
            atomicWrite: writes.write
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
        let completion = await bridge.complete(
            handle: original.handle,
            response: ResponseToExtension(
                for: fixture.request,
                payload: .result(.string("signed"))
            )
        )
        XCTAssertEqual(completion, .persisted)
        clock.now.addTimeInterval(ExtensionBridge.requestTTL + 1)
        bridge = makeBridge(clock: { self.clock.now })

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

    func testReplayOnlyWaitsForClaimResolutionAndRecoversDroppedBroadcast() async throws {
        let fixture = try makeFixture(id: 2)
        let replay = try makeFixture(id: 2, replayOnly: true)
        let original = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let claim = try approvalClaim(await bridge.claim(handle: original.handle))
        guard case .unavailable = await bridge.enqueue(
            ingress: replay.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("An uncommitted claim must keep admission retrying") }
        let release = await bridge.release(claim: claim)
        XCTAssertEqual(release, .persisted)
        guard case .rejected = await bridge.enqueue(
            ingress: replay.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("A released claim must reject the unauthorized retry") }

        let nextClaim = try approvalClaim(await bridge.claim(handle: original.handle))
        let permit = try executionPermit(await bridge.begin(claim: nextClaim))
        let checkpoint = await bridge.prepareBroadcast(
            permit: permit,
            recoveryResponse: ambiguousSubmissionResponse(
                for: fixture.request,
                transactionHash: "0x1234"
            ),
            authority: .ordinary
        )
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
        let fixture = try makeFixture(id: 82)
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
        bridge = makeBridge(clock: { self.clock.now })
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
        bridge = makeBridge(clock: { self.clock.now })
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
        let permit = try executionPermit(await bridge.begin(
            claim: claim.approvalClaim
        ))
        let completion = await bridge.complete(
            permit: permit,
            response: response(for: fixture.request),
            authority: .native(claim.executionContext)
        )
        XCTAssertEqual(completion, .persisted)
        bridge = makeBridge(clock: { self.clock.now })
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
        final class WriteControl {
            var throwsRemaining = 0

            func write(_ data: Data, to url: URL) throws {
                try ApprovalStoreTestPersistence.write(data, url)
                if throwsRemaining > 0, url.pathExtension == "state" {
                    throwsRemaining -= 1
                    throw Failure.injectedWrite
                }
            }
        }
        let writes = WriteControl()
        bridge = makeBridge(
            clock: { self.clock.now },
            atomicWrite: writes.write
        )
        let admission = try accepted(await bridge.enqueue(
            ingress: try makeFixture(id: 84).ingress,
            profileIdentifier: nil
        ))
        let runtime = UUID()

        writes.throwsRemaining = 1
        let recorded = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            owner: storedRequestNativeOwner(runtime: runtime)
        )
        XCTAssertEqual(recorded, .persisted)

        writes.throwsRemaining = 1
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

        let claimFixture = try makeFixture(id: 85)
        let claimAdmission = try accepted(await bridge.enqueue(
            ingress: claimFixture.ingress,
            profileIdentifier: nil
        ))
        let unownedClaim = await bridge.claimNativeExecution(
            handle: claimAdmission.handle,
            nativeDeliveryNonce: claimAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime,
            approvedAt: clock.now
        )
        XCTAssertEqual(unownedClaim, .ownershipLost)
        let recordedClaim = await bridge.recordNativeDeliveryReceipt(
            handle: claimAdmission.handle,
            nativeDeliveryNonce: claimAdmission.nativeDeliveryNonce,
            owner: storedRequestNativeOwner(runtime: firstRuntime)
        )
        XCTAssertEqual(recordedClaim, .persisted)
        let wrongNonceClaim = await bridge.claimNativeExecution(
            handle: claimAdmission.handle,
            nativeDeliveryNonce: wrongNonce,
            runtimeInstanceIdentifier: firstRuntime,
            approvedAt: clock.now
        )
        XCTAssertEqual(wrongNonceClaim, .ownershipLost)
        let wrongOwnerClaim = await bridge.claimNativeExecution(
            handle: claimAdmission.handle,
            nativeDeliveryNonce: claimAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: wrongRuntime,
            approvedAt: clock.now
        )
        XCTAssertEqual(wrongOwnerClaim, .ownershipLost)
        let claimResult = await bridge.claimNativeExecution(
            handle: claimAdmission.handle,
            nativeDeliveryNonce: claimAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime,
            approvedAt: clock.now
        )
        guard case .claimed(let nativeClaim) = claimResult else { return XCTFail("Expected native claim") }
        defer { nativeClaim.approvalClaim.releaseLease() }
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
        let ownerlessCompletion = await bridge.complete(
            handle: completeAdmission.handle,
            response: response(for: completeFixture.request)
        )
        XCTAssertEqual(ownerlessCompletion, .ownershipLost)
        let wrongNonceCompletion = await bridge.completeNativeDelivery(
            handle: completeAdmission.handle,
            nativeDeliveryNonce: wrongNonce,
            runtimeInstanceIdentifier: firstRuntime,
            response: response(for: completeFixture.request)
        )
        XCTAssertEqual(wrongNonceCompletion, .ownershipLost)
        let wrongOwnerCompletion = await bridge.completeNativeDelivery(
            handle: completeAdmission.handle,
            nativeDeliveryNonce: completeAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: wrongRuntime,
            response: response(for: completeFixture.request)
        )
        XCTAssertEqual(wrongOwnerCompletion, .ownershipLost)
        let completion = await bridge.completeNativeDelivery(
            handle: completeAdmission.handle,
            nativeDeliveryNonce: completeAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime,
            response: response(for: completeFixture.request)
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
        final class WriteControl {
            var throwsRemaining = 0

            func write(_ data: Data, to url: URL) throws {
                try ApprovalStoreTestPersistence.write(data, url)
                if throwsRemaining > 0, url.pathExtension == "state" {
                    throwsRemaining -= 1
                    throw Failure.injectedWrite
                }
            }
        }
        let writes = WriteControl()
        bridge = makeBridge(
            clock: { self.clock.now },
            atomicWrite: writes.write
        )
        let firstRuntime = UUID()

        let claimFixture = try makeFixture(id: 88)
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
        writes.throwsRemaining = 1
        let claimResult = await bridge.claimNativeExecution(
            handle: claimAdmission.handle,
            nativeDeliveryNonce: claimAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime,
            approvedAt: clock.now
        )
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
        writes.throwsRemaining = 1
        let completed = await bridge.completeNativeDelivery(
            handle: completeAdmission.handle,
            nativeDeliveryNonce: completeAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime,
            response: response(for: completeFixture.request)
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
        writes.throwsRemaining = 1
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
            enqueueAttempt: attempt,
            favicon: "https://wallet.example/first.png"
        )
        let changedFavicon = try makeFixture(
            id: 4,
            name: "requestAccounts",
            enqueueAttempt: attempt,
            favicon: "https://wallet.example/second.png"
        )
        var changedAuthority = try XCTUnwrap(JSONSerialization.jsonObject(with: original.ingress.canonicalData) as? [String: Any])
        changedAuthority["authority"] = ["context": original.ingress.authority.context, "revisions": ["ethereum": 1, "solana": 0]]
        let changedRevisions = try authorityFixture(changedAuthority)
        let admitted = try accepted(await bridge.enqueue(
            ingress: original.ingress,
            profileIdentifier: nil
        ))
        let faviconRetry = try accepted(await bridge.enqueue(
            ingress: changedFavicon.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(admitted.admissionKind, .new)
        XCTAssertEqual(faviconRetry.admissionKind, .replay)
        XCTAssertEqual(faviconRetry.handle, admitted.handle)
        XCTAssertEqual(faviconRetry.revisions, admitted.revisions)
        guard case .found(let stored) = await bridge.load(handle: admitted.handle) else {
            return XCTFail("Expected stored request")
        }
        XCTAssertEqual(
            stored.request?.favicon,
            "https://wallet.example/first.png"
        )
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

    func testStoredRequestRevisionMismatchFailsClosed() async throws {
        _ = try accepted(await bridge.enqueue(
            ingress: try makeFixture(id: 5, name: "requestAccounts").ingress,
            profileIdentifier: nil
        ))
        try mutateFirstStoredRecord { record in
            var state = try XCTUnwrap(record["state"] as? [String: Any])
            var pending = try XCTUnwrap(state["pending"] as? [String: Any])
            let requestData = try XCTUnwrap(pending["request"] as? Data)
            var request = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestData) as? [String: Any]
            )
            var authority = try XCTUnwrap(request["authority"] as? [String: Any])
            authority["revisions"] = ["ethereum": 1, "solana": 0]
            request["authority"] = authority
            pending["request"] = try JSONSerialization.data(
                withJSONObject: request,
                options: [.sortedKeys]
            )
            state["pending"] = pending
            record["state"] = state
        }

        guard case .unavailable = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected revision mismatch to fail closed")
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
        let observer = makeBridge(clock: { self.clock.now })
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
        let completion = await bridge.complete(
            handle: first.handle,
            response: ResponseToExtension(for: original.request, payload: .error(.userRejected))
        )
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

    func testManualSwitchDiscoveryDescribesStoredStatesAndRequiresExactIdentity()
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
        defer { nativeClaim.approvalClaim.releaseLease() }
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
        let completion = await bridge.complete(
            handle: completedHandle,
            response: ResponseToExtension(for: completed.request, payload: .error(.userRejected))
        )
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

        let page = try manualSwitchRequests(await bridge.listManualSwitchRequests(
            profileIdentifier: nil
        ))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: page.map {
            ($0.handle, $0.state)
        }), [pendingHandle: .pending, approvedHandle: .approved, completedHandle: .completed])
        for request in page {
            XCTAssertEqual(Set(request.json.keys), [
                "id", "host", "configurationKey", "requestToken", "revisions", "state",
            ])
        }
        let pendingDescriptor = try XCTUnwrap(page.first { $0.handle == pendingHandle })
        XCTAssertEqual(pendingDescriptor.revisions, pending.ingress.authority.revisions)
        XCTAssertEqual(pendingDescriptor.host, pending.request.host)
        XCTAssertEqual(pendingDescriptor.configurationKey, pending.request.configurationKey)
        guard case .found(let completedSnapshot) = await bridge.loadManualSwitch(
            handle: completedHandle,
            configurationKey: completed.request.configurationKey
        ) else { return XCTFail("Completed switches must retain their classification") }
        XCTAssertNil(completedSnapshot.request)
        XCTAssertEqual(completedSnapshot.phase, .responded)

        for (handle, origin) in [
            (pendingHandle, "https://other.example"),
            (ordinary, pending.request.configurationKey),
            (ExtensionBridge.Handle(
                id: foreign.id,
                token: foreign.token,
                profileIdentifier: nil
            ), pending.request.configurationKey),
        ] {
            guard case .missing = await bridge.loadManualSwitch(
                handle: handle,
                configurationKey: origin
            ) else { return XCTFail("Switch reads must require exact type, origin, and profile") }
        }
        let acknowledged = await bridge.acknowledgeResponse(
            handle: completedHandle,
            configurationKey: completed.request.configurationKey
        )
        XCTAssertEqual(acknowledged, .persisted)
        guard case .missing = await bridge.loadManualSwitch(
            handle: completedHandle,
            configurationKey: completed.request.configurationKey
        ) else { return XCTFail("Acknowledged switches must not be recovered") }
        let remaining = try manualSwitchRequests(await bridge.listManualSwitchRequests(
            profileIdentifier: nil
        ))
        XCTAssertEqual(Set(remaining.map(\.handle)), [pendingHandle, approvedHandle])
        let foreignPage = try manualSwitchRequests(await bridge.listManualSwitchRequests(
            profileIdentifier: foreignProfile
        ))
        XCTAssertEqual(foreignPage.map(\.handle), [foreign])
    }

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
            let completed = await bridge.complete(
                handle: handle,
                response: ResponseToExtension(
                    for: manual.request,
                    payload: .result(.null),
                    mutation: .accounts([.disconnectEthereum])
                ).markingApprovalCommitted()
            )
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
        let requests = try manualSwitchRequests(await bridge.listManualSwitchRequests(profileIdentifier: nil))
        XCTAssertEqual(requests.map(\.handle), handles)
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

    func testManualSwitchCompletionSurvivesAdmissionBytePressure() async throws {
        let manual = try makeManualFixture(
            id: 810,
            enqueueAttempt: attempt(for: 810),
            latestConfigurations: []
        )
        let handle = try accepted(await bridge.enqueue(ingress: manual.ingress, profileIdentifier: nil)).handle
        let completed = await bridge.complete(
            handle: handle,
            response: response(for: manual.request).markingApprovalCommitted()
        )
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
        guard case .found(let retained) = await bridge.loadManualSwitch(
            handle: handle, configurationKey: manual.request.configurationKey
        ) else { return XCTFail("An unacknowledged selection must survive admission pressure") }
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

    func testManualSwitchDiscoveryLeavesExpirationToExplicitMaintenance()
        async throws {
        let manual = try makeManualFixture(
            id: 490,
            enqueueAttempt: attempt(for: 490),
            latestConfigurations: []
        )
        let handle = try accepted(await bridge.enqueue(
            ingress: manual.ingress,
            profileIdentifier: nil
        )).handle
        clock.now = manual.request.admissionDeadline
        let pending = try manualSwitchRequests(await bridge.listManualSwitchRequests(profileIdentifier: nil))
        XCTAssertEqual(pending.map(\.state), [.pending])
        await bridge.performMaintenance(profileIdentifier: nil)
        let expired = try manualSwitchRequests(await bridge.listManualSwitchRequests(
            profileIdentifier: nil
        ))
        XCTAssertEqual(expired.map(\.state), [.completed])
        clock.now.addTimeInterval(ExtensionBridge.responseExpiry)
        await bridge.performMaintenance(profileIdentifier: nil)
        let retired = try manualSwitchRequests(await bridge.listManualSwitchRequests(
            profileIdentifier: nil
        ))
        XCTAssertTrue(retired.isEmpty)
        try Data("corrupt profile".utf8).write(to: defaultProfileURL, options: .atomic)
        let unavailable = await bridge.listManualSwitchRequests(profileIdentifier: nil)
        XCTAssertEqual(unavailable, .unavailable)
        guard case .unavailable = await bridge.loadManualSwitch(
            handle: handle,
            configurationKey: manual.request.configurationKey
        ) else { return XCTFail("Corrupt storage must not look like a missing switch") }
    }

    func testCompletedRecordWithInvalidRevisionsFailsClosed() async throws {
        let fixture = try makeFixture(id: 6)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let completion = await bridge.complete(
            handle: handle,
            response: response(for: fixture.request)
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
            let result = await bridge.complete(
                handle: handle,
                response: response(for: fixture.request)
            )
            XCTAssertEqual(result, .persisted)
            completed.append((fixture, handle))
        }
        let oldest = try XCTUnwrap(completed.first)
        let observer = makeBridge(clock: { self.clock.now })
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
        let completion = await bridge.complete(
            handle: handle,
            response: response(for: fixture.request)
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
        let observer = makeBridge(clock: { self.clock.now })
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
            clock: { self.clock.now },
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
            let completion = await bridge.complete(
                handle: handle,
                response: response(for: fixture.request)
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
            let observer = makeBridge(clock: { self.clock.now })
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
        let completion = await bridge.complete(
            handle: handle,
            response: response(for: fixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        let failingWriter = makeBridge(
            clock: { self.clock.now },
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
            clock: { self.clock.now },
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
            var recovering = false
            var recoveryReads = 0
            let writer = makeBridge(
                clock: { self.clock.now },
                atomicWrite: { data, url in
                    guard url == targetURL else {
                        return try ApprovalStoreTestPersistence.write(data, url)
                    }
                    recovering = true
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
                        let otherURL = self.rootURL.appendingPathComponent("readback-target")
                        try data.write(to: otherURL, options: .atomic)
                        try FileManager.default.removeItem(at: url)
                        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: otherURL)
                    case .exact, .unreadable, .oversizedFile, .oversizedData, .emptyData:
                        try ApprovalStoreTestPersistence.write(data, url)
                    }
                    throw Failure.injectedWrite
                },
                readData: { url in
                    if recovering, url == targetURL {
                        recoveryReads += 1
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
                    if recovering, url == targetURL, mode == .oversizedFile {
                        return Int.max
                    }
                    return try ExtensionRequestFileStore.defaultReadFileSize(url)
                }
            )
            let result = await writer.complete(
                handle: handle,
                response: response(for: fixture.request)
            )
            XCTAssertEqual(
                result,
                mode == .exact ? .persisted : .retryablePersistenceFailure,
                "Read-back mode: \(mode)"
            )
            if [.missing, .symbolicLink, .oversizedFile].contains(mode) {
                XCTAssertEqual(recoveryReads, 0, "Unsafe or unbounded data must not be read")
            }
        }
    }

    func testResponseAcknowledgmentRequiresCompletedExactIdentity() async throws {
        let fixture = try makeFixture(id: 1)
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
        let permit = try executionPermit(await bridge.begin(claim: claim))
        let prepared = await bridge.prepareBroadcast(
            permit: permit,
            recoveryResponse: response(for: fixture.request),
            authority: .ordinary
        )
        XCTAssertEqual(prepared, .persisted)
        let broadcasting = await bridge.acknowledgeResponse(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        )
        XCTAssertEqual(broadcasting, .retryablePersistenceFailure)
        let completion = await bridge.complete(
            permit: permit,
            response: response(for: fixture.request),
            authority: .ordinary
        )
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
        XCTAssertEqual(protectedResponse["result"] as? String, largeResponseResult)

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
        let prepared = try makeFixture(id: 2, host: "prepared.example")
        let preparedHandle = try accepted(await bridge.enqueue(
            ingress: prepared.ingress,
            profileIdentifier: nil
        )).handle
        let preparedClaim = try approvalClaim(await bridge.claim(handle: preparedHandle))
        let permit = try executionPermit(await bridge.begin(claim: preparedClaim))
        let recovery = ambiguousSubmissionResponse(for: prepared.request, transactionHash: "0x1234")
        let preparation = await bridge.prepareBroadcast(
            permit: permit,
            recoveryResponse: recovery,
            authority: .ordinary
        )
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
        let release = await bridge.release(claim: claim)
        XCTAssertEqual(release, .persisted)
        let completion = await bridge.complete(permit: permit, response: recovery, authority: .ordinary)
        XCTAssertEqual(completion, .persisted)
    }

    func testAdmissionReservesSpaceForNativeBroadcastAndCompletion() async throws {
        let fixture = try makeFixture(
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
        let permit = try executionPermit(await bridge.begin(claim: claim.approvalClaim))
        _ = try await fillCompletedByteCapacity()
        let prepared = await bridge.prepareBroadcast(
            permit: permit,
            recoveryResponse: largeResponse(for: fixture.request),
            authority: .native(claim.executionContext)
        )
        XCTAssertEqual(prepared, .persisted)
        guard case .found(let checkpoint) = await bridge.load(handle: admission.handle) else {
            return XCTFail("Expected prepared native broadcast")
        }
        XCTAssertNotNil(checkpoint.nativeApproval)
        XCTAssertEqual(checkpoint.nativeDeliveryReceipt?.owner, owner)
        XCTAssertNil(checkpoint.nativeExecutionContext)
        let completion = await bridge.complete(
            permit: permit,
            response: largeResponse(for: fixture.request),
            authority: .ordinary
        )
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
        let completion = await bridge.complete(
            handle: completedHandle,
            response: response(for: completed.request)
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

        let completion = await bridge.complete(
            handle: handle,
            response: response(for: fixture.request)
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
        let completion = await bridge.complete(
            handle: first,
            response: response(for: fixture.request)
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
        let completion = await bridge.complete(
            handle: handle,
            response: response(for: fixture.request)
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
        let completion = await bridge.complete(
            handle: handle,
            response: response(for: fixture.request)
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
        defer { heldClaims.forEach { $0.releaseLease() } }
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
                let completed = await bridge.complete(handle: handle, response: response(for: fixture.request))
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
        claim?.releaseLease()
        claim = nil

        let observer = makeBridge(clock: { self.clock.now })
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
        claim?.releaseLease()
        claim = nil

        let observer = makeBridge(clock: { self.clock.now })
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

    func testReleaseAndRollbackRestoreActiveClaimsAndRetainExpiredRejections() async throws {
        for (operationIndex, rollsBack) in [false, true].enumerated() {
            for (expiryIndex, expires) in [false, true].enumerated() {
                let fixture = try makeFixture(id: 950 + operationIndex * 2 + expiryIndex)
                let handle = try accepted(await bridge.enqueue(
                    ingress: fixture.ingress,
                    profileIdentifier: nil
                )).handle
                let claim = try approvalClaim(await bridge.claim(handle: handle))
                let permit = rollsBack ? try executionPermit(await bridge.begin(claim: claim)) : nil
                if expires { clock.now.addTimeInterval(ExtensionBridge.requestTTL) }

                let result: ExtensionBridge.StoreMutationResult
                if rollsBack {
                    result = await bridge.rollback(permit: try XCTUnwrap(permit))
                } else {
                    result = await bridge.release(claim: claim)
                }
                XCTAssertEqual(result, expires ? .ownershipLost : .persisted)
                XCTAssertFalse(FileManager.default.fileExists(atPath: operationLockURL(handle).path))
                guard case .found(let released) = await bridge.load(handle: handle) else {
                    return XCTFail("Expected retained request")
                }
                XCTAssertEqual(released.phase, expires ? .responded : .queued)
                if expires {
                    let response = try responseJSON(await bridge.prepareResponseDelivery(
                        id: handle.id,
                        configurationKey: fixture.request.configurationKey,
                        requestToken: handle.requestToken,
                        profileIdentifier: nil
                    ))
                    XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, 4001)
                } else {
                    let reclaimed = try approvalClaim(await bridge.claim(handle: handle))
                    let release = await bridge.release(claim: reclaimed)
                    XCTAssertEqual(release, .persisted)
                }
            }
        }
    }

    func testClaimAbandonmentPreservesWriteRecoveryAndLeaseOwnership() async throws {
        for (nativeIndex, native) in [false, true].enumerated() {
            for (operationIndex, rollsBack) in [false, true].enumerated() {
                for (failureIndex, persistsBeforeFailure) in [false, true].enumerated() {
                    let fixture = try makeFixture(
                        id: 960 + nativeIndex * 4 + operationIndex * 2 + failureIndex
                    )
                    let handle = try accepted(await bridge.enqueue(
                        ingress: fixture.ingress,
                        profileIdentifier: nil
                    )).handle
                    let claim: ExtensionBridge.ApprovalClaim
                    if native {
                        let delivered = try await recordNativeDelivery(handle: handle)
                        XCTAssertEqual(delivered, .persisted)
                        guard case .claimed(let nativeClaim) = await claimDeliveredNativeExecution(
                            in: bridge,
                            handle: handle,
                            approvedAt: clock.now
                        ) else { return XCTFail("Expected native claim") }
                        claim = nativeClaim.approvalClaim
                    } else {
                        claim = try approvalClaim(await bridge.claim(handle: handle))
                    }
                    defer { claim.releaseLease() }
                    let failingWriter = makeBridge(
                        clock: { self.clock.now },
                        atomicWrite: { data, url in
                            if persistsBeforeFailure {
                                try ApprovalStoreTestPersistence.write(data, url)
                            }
                            throw Failure.injectedWrite
                        }
                    )
                    let result: ExtensionBridge.StoreMutationResult
                    if rollsBack {
                        let permit = try executionPermit(await bridge.begin(claim: claim))
                        result = await failingWriter.rollback(permit: permit)
                    } else {
                        result = await failingWriter.release(claim: claim)
                    }

                    if native && persistsBeforeFailure {
                        XCTAssertEqual(result, .persisted)
                        XCTAssertFalse(FileManager.default.fileExists(atPath: operationLockURL(handle).path))
                    } else {
                        XCTAssertEqual(result, .retryablePersistenceFailure)
                        let competingLock = CrossProcessFileLock(fileURL: operationLockURL(handle))
                        XCTAssertFalse(try competingLock.tryAcquireExisting())
                        competingLock.release()
                    }
                    if !persistsBeforeFailure {
                        guard case .found(let retained) = await bridge.load(handle: handle) else {
                            return XCTFail("Expected retained claim")
                        }
                        XCTAssertEqual(retained.phase, .approving)
                        let retried = await bridge.release(claim: claim)
                        XCTAssertEqual(retried, .persisted)
                    }
                    claim.releaseLease()
                    guard case .found(let recovered) = await bridge.load(handle: handle) else {
                        return XCTFail("Expected persisted abandonment")
                    }
                    XCTAssertEqual(recovered.phase, native ? .responded : .queued)
                    if native {
                        let response = try responseJSON(await bridge.prepareResponseDelivery(
                            id: handle.id,
                            configurationKey: fixture.request.configurationKey,
                            requestToken: handle.requestToken,
                            profileIdentifier: handle.profileIdentifier
                        ))
                        XCTAssertEqual(
                            NSDictionary(dictionary: response),
                            NSDictionary(dictionary: ResponseToExtension(
                                for: fixture.request,
                                payload: .error(.approvalInterrupted)
                            ).json)
                        )
                    } else {
                        let rejected = await bridge.reject(handle: handle)
                        XCTAssertEqual(rejected, .persisted)
                    }
                }
            }
        }
    }

    func testClaimCanBeginExecutionOnlyOnce() async throws {
        let fixture = try makeFixture(id: 41)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))

        _ = try executionPermit(await bridge.begin(claim: claim))
        let repeatedBegin = await bridge.begin(claim: claim)
        XCTAssertEqual(repeatedBegin, .ownershipLost)
    }

    func testOrdinaryClaimDeadlineRoundTripsAndEndsAtBroadcastCheckpoint() async throws {
        let fixture = try makeFixture(id: 989)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress, profileIdentifier: nil
        )).handle
        let firstClaim = try approvalClaim(await bridge.claim(handle: handle))
        defer { firstClaim.releaseLease() }
        let claimedState = try firstStoredState("claimed")
        let approval = try XCTUnwrap(claimedState["approval"] as? [String: Any])
        let ordinary = try XCTUnwrap(approval["ordinary"] as? [String: Any])
        XCTAssertEqual(ordinary["deadline"] as? Date, firstClaim.executionDeadline)
        let claimedRecords = try XCTUnwrap(try storedProfile()["records"] as? [[String: Any]])
        XCTAssertNil(claimedRecords.first?["executionDeadline"])

        let observer = makeBridge(clock: { self.clock.now })
        let firstPermit = try executionPermit(await observer.begin(claim: firstClaim))
        let rolledBack = await observer.rollback(permit: firstPermit)
        XCTAssertEqual(rolledBack, .persisted)
        _ = try firstStoredState("pending")
        clock.now.addTimeInterval(1)
        let nextClaim = try approvalClaim(await observer.claim(handle: handle))
        defer { nextClaim.releaseLease() }
        XCTAssertGreaterThan(nextClaim.executionDeadline, firstClaim.executionDeadline)
        let nextPermit = try executionPermit(await observer.begin(claim: nextClaim))
        let recovery = ambiguousSubmissionResponse(for: fixture.request, transactionHash: "0x989")
        let checkpointed = await observer.prepareBroadcast(
            permit: nextPermit, recoveryResponse: recovery, authority: .ordinary
        )
        XCTAssertEqual(checkpointed, .persisted)
        let broadcastState = try firstStoredState("broadcastPrepared")
        let broadcastApproval = try XCTUnwrap(broadcastState["approval"] as? [String: Any])
        let ordinaryBroadcast = try XCTUnwrap(broadcastApproval["ordinary"] as? [String: Any])
        XCTAssertTrue(ordinaryBroadcast.isEmpty)

        clock.now = nextClaim.executionDeadline.addingTimeInterval(1)
        let completed = await observer.complete(
            permit: nextPermit, response: recovery, authority: .ordinary
        )
        XCTAssertEqual(completed, .persisted)
        let completedRecords = try XCTUnwrap(try storedProfile()["records"] as? [[String: Any]])
        XCTAssertNil(completedRecords.first?["executionDeadline"])
        _ = try firstStoredState("completed")
    }

    func testExecutionWriteFailuresRecoverAccordingToThePersistedPhase()
        async throws {
        for (operationIndex, checkpointsBroadcast) in [false, true].enumerated() {
            for (failureIndex, persistsBeforeFailure) in [false, true].enumerated() {
                bridge = makeBridge(clock: { self.clock.now })
                let fixture = try makeFixture(id: 740 + operationIndex * 2 + failureIndex)
                let handle = try accepted(await bridge.enqueue(
                    ingress: fixture.ingress,
                    profileIdentifier: nil
                )).handle
                let claim = try approvalClaim(await bridge.claim(handle: handle))
                let permit = try executionPermit(await bridge.begin(claim: claim))
                let failingWriter = makeBridge(
                    clock: { self.clock.now },
                    atomicWrite: { data, url in
                        if persistsBeforeFailure {
                            try ApprovalStoreTestPersistence.write(data, url)
                        }
                        throw Failure.injectedWrite
                    }
                )
                let expectedResponse = checkpointsBroadcast
                    ? ambiguousSubmissionResponse(
                        for: fixture.request,
                        transactionHash: "0x1234"
                    ).markingApprovalCommitted()
                    : response(for: fixture.request).markingApprovalCommitted()
                let result: ExtensionBridge.StoreMutationResult
                if checkpointsBroadcast {
                    result = await failingWriter.prepareBroadcast(
                        permit: permit,
                        recoveryResponse: expectedResponse,
                        authority: .ordinary
                    )
                } else {
                    result = await failingWriter.complete(
                        permit: permit,
                        response: expectedResponse,
                        authority: .ordinary
                    )
                }
                XCTAssertEqual(result, .retryablePersistenceFailure)
                let observer = makeBridge(clock: { self.clock.now })
                guard case .found(let held) = await observer.load(handle: handle) else {
                    return XCTFail("Expected retained failed execution")
                }
                XCTAssertEqual(
                    held.phase,
                    persistsBeforeFailure && !checkpointsBroadcast ? .responded : .approving
                )

                permit.releaseLease()
                let restarted = makeBridge(clock: { self.clock.now })
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
        let profiles = storeRoot.appendingPathComponent("profiles-v8", isDirectory: true)
        let expectedPaths = [profiles, storeRoot, support, library, container].map(\.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))

        var operations = DurableProfilePersistence.Operations.live
        let openDirectory = operations.openDirectory
        let syncDirectory = operations.syncDirectory
        var directoryPaths = [Int32: String]()
        var openedPaths = [String]()
        var synchronizedPaths = [String]()
        var failBoundarySynchronization = false
        operations.openDirectory = { path in
            let descriptor = try openDirectory(path)
            directoryPaths[descriptor] = path
            openedPaths.append(path)
            return descriptor
        }
        operations.syncDirectory = { descriptor in
            let path = try XCTUnwrap(directoryPaths[descriptor])
            synchronizedPaths.append(path)
            if failBoundarySynchronization, path == container.path {
                throw Failure.injectedWrite
            }
            try syncDirectory(descriptor)
        }
        let store = ExtensionRequestFileStore(
            containerURL: container,
            dependencies: .init(clock: { self.clock.now }, persistenceOperations: operations)
        )
        let template = try makeFixture(id: 982)
        guard case .snapshot(let snapshot) = store.configurationSnapshot(configurationKey: template.request.configurationKey, profileIdentifier: nil) else { return XCTFail("Expected container authority") }
        XCTAssertEqual(openedPaths, expectedPaths)
        XCTAssertEqual(synchronizedPaths, expectedPaths)
        openedPaths.removeAll()
        synchronizedPaths.removeAll()
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: template.ingress.canonicalData) as? [String: Any])
        raw["authority"] = snapshot.version.json
        let fixture = try authorityFixture(raw)
        let handle = try accepted(store.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        XCTAssertEqual(openedPaths, expectedPaths)
        XCTAssertEqual(synchronizedPaths, expectedPaths)

        let expectedResponse = response(for: fixture.request)
        XCTAssertEqual(store.complete(handle: handle, response: expectedResponse), .persisted)
        openedPaths.removeAll()
        synchronizedPaths.removeAll()
        failBoundarySynchronization = true
        guard case .unavailable = store.prepareResponseDelivery(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        ) else { return XCTFail("Response reads must synchronize through the container boundary") }
        XCTAssertEqual(openedPaths, expectedPaths)
        XCTAssertEqual(synchronizedPaths, expectedPaths)

        openedPaths.removeAll()
        synchronizedPaths.removeAll()
        failBoundarySynchronization = false
        let recovered = try responseJSON(store.prepareResponseDelivery(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        ))
        XCTAssertEqual(recovered as NSDictionary, expectedResponse.json as NSDictionary)
        XCTAssertEqual(openedPaths, expectedPaths)
        XCTAssertEqual(synchronizedPaths, expectedPaths)
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
        var failSynchronization = true
        var synchronizedURLs = [URL]()
        let observer = makeBridge(
            clock: { self.clock.now },
            atomicWrite: { data, url in
                try data.write(to: url, options: .atomic)
                throw Failure.injectedWrite
            },
            synchronizePublishedFile: { url in
                synchronizedURLs.append(url)
                if failSynchronization { throw Failure.injectedWrite }
                try ApprovalStoreTestPersistence.synchronize(url)
            }
        )

        let completion = await observer.complete(handle: handle, response: expected)
        XCTAssertEqual(completion, .retryablePersistenceFailure)
        XCTAssertEqual(try firstStoredState("completed")["acknowledged"] as? Bool, false)
        XCTAssertEqual(synchronizedURLs, [defaultProfileURL])
        guard case .unavailable = await observer.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ) else { return XCTFail("Visible response bytes must not bypass failed synchronization") }
        XCTAssertEqual(synchronizedURLs.count, 2)

        failSynchronization = false
        let recovered = try responseJSON(await observer.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(recovered as NSDictionary, expected.json as NSDictionary)
        XCTAssertEqual(synchronizedURLs.count, 3)
    }

    func testRepeatedExecutionCommitRequiresSynchronizationAndRetainsItsLeaseOnFailure()
        async throws {
        for (index, checkpointsBroadcast) in [false, true].enumerated() {
            let profileIdentifier = UUID()
            let fixture = try makeFixture(id: 975 + index)
            let handle = try accepted(await bridge.enqueue(
                ingress: try profileFixture(fixture, profileIdentifier: profileIdentifier).ingress,
                profileIdentifier: profileIdentifier
            )).handle
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            let permit = try executionPermit(await bridge.begin(claim: claim))
            defer { permit.releaseLease() }
            let expected = checkpointsBroadcast
                ? ambiguousSubmissionResponse(
                    for: fixture.request,
                    transactionHash: "0x1234"
                ).markingApprovalCommitted()
                : response(for: fixture.request).markingApprovalCommitted()
            var failSynchronization = true
            var synchronizationAttempts = 0
            let writer = makeBridge(
                clock: { self.clock.now },
                atomicWrite: { data, url in
                    try data.write(to: url, options: .atomic)
                    throw Failure.injectedWrite
                },
                synchronizePublishedFile: { url in
                    synchronizationAttempts += 1
                    XCTAssertEqual(url, self.profileURL(profileIdentifier))
                    if failSynchronization { throw Failure.injectedWrite }
                    try ApprovalStoreTestPersistence.synchronize(url)
                }
            )
            func commit() async -> ExtensionBridge.StoreMutationResult {
                if checkpointsBroadcast {
                    return await writer.prepareBroadcast(
                        permit: permit,
                        recoveryResponse: expected,
                        authority: .ordinary
                    )
                }
                return await writer.complete(
                    permit: permit,
                    response: expected,
                    authority: .ordinary
                )
            }

            let first = await commit()
            XCTAssertEqual(first, .retryablePersistenceFailure)
            let repeated = await commit()
            XCTAssertEqual(repeated, .retryablePersistenceFailure)
            XCTAssertEqual(synchronizationAttempts, 1)
            let competingLock = CrossProcessFileLock(fileURL: operationLockURL(handle))
            XCTAssertFalse(try competingLock.tryAcquireExisting())
            competingLock.release()

            failSynchronization = false
            let retried = await commit()
            XCTAssertEqual(retried, .persisted)
            XCTAssertEqual(synchronizationAttempts, 2)
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
        let completed = await bridge.complete(
            handle: handle,
            response: response(for: fixture.request)
        )
        XCTAssertEqual(completed, .persisted)
        var failSynchronization = true
        var synchronizationAttempts = 0
        let writer = makeBridge(
            clock: { self.clock.now },
            atomicWrite: { data, url in
                try data.write(to: url, options: .atomic)
                throw Failure.injectedWrite
            },
            synchronizePublishedFile: { url in
                synchronizationAttempts += 1
                if failSynchronization { throw Failure.injectedWrite }
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
        XCTAssertEqual(synchronizationAttempts, 2)

        failSynchronization = false
        let retried = await writer.acknowledgeResponse(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        )
        XCTAssertEqual(retried, .persisted)
        XCTAssertEqual(synchronizationAttempts, 3)
        guard case .available(let listed) = await writer.list(profileIdentifier: nil) else {
            return XCTFail("Expected synchronized acknowledgment to remain readable")
        }
        XCTAssertTrue(listed.isEmpty)
    }

    func testFailedUnrelatedProfileMutationPreservesBroadcastRecovery()
        async throws {
        let fixture = try makeFixture(id: 978)
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
        let permit = try executionPermit(await bridge.begin(claim: claim))
        defer { permit.releaseLease() }
        let recovery = ambiguousSubmissionResponse(
            for: fixture.request,
            transactionHash: "0x1234"
        ).markingApprovalCommitted()
        let prepared = await bridge.prepareBroadcast(
            permit: permit,
            recoveryResponse: recovery,
            authority: .ordinary
        )
        XCTAssertEqual(prepared, .persisted)
        let failingWriter = makeBridge(
            clock: { self.clock.now },
            atomicWrite: { data, url in
                try data.write(to: url, options: .atomic)
                throw Failure.injectedWrite
            },
            synchronizePublishedFile: { _ in throw Failure.injectedWrite }
        )
        let rejected = await failingWriter.reject(handle: otherHandle)
        XCTAssertEqual(rejected, .retryablePersistenceFailure)
        let repeatedCheckpoint = await failingWriter.prepareBroadcast(
            permit: permit,
            recoveryResponse: recovery,
            authority: .ordinary
        )
        XCTAssertEqual(repeatedCheckpoint, .retryablePersistenceFailure)

        permit.releaseLease()
        let restarted = makeBridge(clock: { self.clock.now })
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
    func testBroadcastIsNotSentWhenCheckpointPublicationCannotBeSynchronized()
        async throws {
        let fixture = try makeFixture(id: 980)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        defer { claim.releaseLease() }
        let recovery = ambiguousSubmissionResponse(
            for: fixture.request,
            transactionHash: "0x1234"
        )
        var synchronizationAttempts = 0
        let synchronize: (URL) throws -> Void = { _ in
            synchronizationAttempts += 1
            throw Failure.injectedWrite
        }
        let writer = makeBridge(
            clock: { self.clock.now },
            atomicWrite: { data, url in
                try data.write(to: url, options: .atomic)
                try synchronize(url)
            },
            synchronizePublishedFile: synchronize
        )
        let executor = DurableApprovalExecutor(store: writer)
        var sends = 0
        let result = await executor.executeOrdinary(claim: claim) {
            .broadcast(PreparedBroadcast(recoveryResponse: recovery, send: {
                sends += 1
                return self.response(for: fixture.request)
            }))
        }
        XCTAssertEqual(result, .retryablePersistenceFailure)
        XCTAssertEqual(synchronizationAttempts, 1)
        XCTAssertEqual(sends, 0)

        claim.releaseLease()
        let recovered = try responseJSON(await bridge.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(
            recovered as NSDictionary,
            recovery.markingApprovalCommitted().json as NSDictionary
        )
        XCTAssertEqual(sends, 0)
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
        var failSynchronization = true
        let observer = makeBridge(
            clock: { self.clock.now },
            atomicWrite: { _, _ in XCTFail("An exact native retry must not rewrite the profile") },
            synchronizePublishedFile: { url in
                if failSynchronization { throw Failure.injectedWrite }
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
            failSynchronization = false
        }
    }

    func testExecutionDeadlineRejectsCommitAtExactStoreBoundary()
        async throws {
        for (index, checkpointsBroadcast) in [false, true].enumerated() {
            let fixture = try makeFixture(id: 735 + index)
            let handle = try accepted(await bridge.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: nil
            )).handle
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            let permit = try executionPermit(await bridge.begin(claim: claim))
            let deadline = claim.executionDeadline
            clock.now = deadline

            let result: ExtensionBridge.StoreMutationResult
            if checkpointsBroadcast {
                result = await bridge.prepareBroadcast(
                    permit: permit,
                    recoveryResponse: response(for: fixture.request),
                    authority: .mobileSigning(deadline: deadline)
                )
            } else {
                result = await bridge.complete(
                    permit: permit,
                    response: response(for: fixture.request),
                    authority: .mobileSigning(deadline: deadline)
                )
            }

            XCTAssertEqual(result, .ownershipLost)
            guard case .found(let retained) = await bridge.load(
                      handle: handle
                  ) else {
                return XCTFail("Expected retained execution")
            }
            XCTAssertEqual(retained.phase, .approving)
            let rollback = await bridge.rollback(permit: permit)
            XCTAssertEqual(rollback, .persisted)
        }
    }

    func testExpiredHeldClaimRetainsOwnershipButCannotBeginExecution() async throws {
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

        let begin = await bridge.begin(claim: claim)
        XCTAssertEqual(begin, .ownershipLost)
        claim.releaseLease()
    }

    func testHeldPreparedBroadcastDoesNotExpireUntilItsLeaseEnds() async throws {
        let fixture = try makeFixture(id: 43)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        var permit: ExtensionBridge.ExecutionPermit? = try executionPermit(
            await bridge.begin(claim: claim)
        )
        let recovery = ambiguousSubmissionResponse(
            for: fixture.request,
            transactionHash: "0x5678"
        )
        let preparation = await bridge.prepareBroadcast(
            permit: try XCTUnwrap(permit),
            recoveryResponse: recovery,
            authority: .ordinary
        )
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

    func testExpiredNativeDeadlinePreventsBroadcastCheckpoint() async throws {
        let fixture = try makeFixture(id: 44)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        clock.now.addTimeInterval(ExtensionBridge.requestTTL - 1)
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        var permit: ExtensionBridge.ExecutionPermit? = try executionPermit(
            await bridge.begin(claim: claim)
        )
        clock.now.addTimeInterval(2)
        let recovery = ambiguousSubmissionResponse(
            for: fixture.request,
            transactionHash: "0x9abc"
        )
        let preparation = await bridge.prepareBroadcast(
            permit: try XCTUnwrap(permit),
            recoveryResponse: recovery,
            authority: .ordinary
        )
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

    func testDroppedPreparedBroadcastCompletesWithUnknownSubmissionResponse() async throws {
        let fixture = try makeFixture(id: 50)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        var claim: ExtensionBridge.ApprovalClaim? = try approvalClaim(
            await bridge.claim(handle: handle)
        )
        var permit: ExtensionBridge.ExecutionPermit? = try executionPermit(
            await bridge.begin(claim: try XCTUnwrap(claim))
        )
        let recovery = ambiguousSubmissionResponse(
            for: fixture.request,
            transactionHash: "0x1234"
        )
        let preparation = await bridge.prepareBroadcast(
            permit: try XCTUnwrap(permit),
            recoveryResponse: recovery,
            authority: .ordinary
        )
        XCTAssertEqual(preparation, .persisted)
        permit?.releaseLease()
        permit = nil
        claim = nil

        let observer = makeBridge(clock: { self.clock.now })
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

    func testBroadcastRejectionPreservesFullRangeRPCErrorCodes() async throws {
        for (index, code) in [9_007_199_254_740_992, -9_007_199_254_740_992, Int.min, Int.max].enumerated() {
            let fixture = try makeFixture(id: 80 + index)
            let handle = try accepted(await bridge.enqueue(
                ingress: fixture.ingress, profileIdentifier: nil
            )).handle
            let claim = try approvalClaim(await bridge.claim(handle: handle))
            let permit = try executionPermit(await bridge.begin(claim: claim))
            let recovery = ambiguousSubmissionResponse(
                for: fixture.request, transactionHash: "0x1234"
            ).markingApprovalCommitted()
            let preparation = await bridge.prepareBroadcast(
                permit: permit, recoveryResponse: recovery, authority: .ordinary
            )
            XCTAssertEqual(preparation, .persisted)
            let rejection = EthereumDappRequestProcessor.transactionBroadcastResponse(
                to: fixture.request, expectedHash: "0x1234", recoveryResponse: recovery,
                result: .failure(.rpc(.serverError(code, "Rejected", dataJSON: #"{"reason":"custom"}"#)))
            ).markingApprovalCommitted()
            let completion = await bridge.complete(
                permit: permit, response: rejection, authority: .ordinary
            )
            XCTAssertEqual(completion, .persisted)

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

    func testOversizedBroadcastCompletionPreservesRecoveryResponse() async throws {
        let fixture = try makeFixture(id: 51)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        let permit = try executionPermit(await bridge.begin(claim: claim))
        let recovery = ambiguousSubmissionResponse(
            for: fixture.request,
            transactionHash: "0x1234"
        ).markingApprovalCommitted()
        let preparation = await bridge.prepareBroadcast(
            permit: permit,
            recoveryResponse: recovery,
            authority: .ordinary
        )
        XCTAssertEqual(preparation, .persisted)
        let oversized = oversizedCommittedError(for: fixture.request)

        let completion = await bridge.complete(
            permit: permit,
            response: oversized,
            authority: .ordinary
        )
        XCTAssertEqual(completion, .persisted)
        let delivered = try responseJSON(await bridge.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(
            delivered["approvalCommitted"] as? Bool,
            true
        )
        XCTAssertEqual(
            (delivered["error"] as? [String: Any])?["code"] as? Int,
            ProviderResponseError.transactionSubmissionUnknownCode
        )
        XCTAssertEqual(
            (delivered["error"] as? [String: Any])?["data"] as? [String: String],
            ["transactionHash": "0x1234"]
        )
    }

    func testOversizedApprovedCompletionPreservesCommittedMarker() async throws {
        let fixture = try makeFixture(id: 52)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        let permit = try executionPermit(await bridge.begin(claim: claim))
        let oversized = oversizedCommittedError(for: fixture.request)

        let completion = await bridge.complete(
            permit: permit,
            response: oversized,
            authority: .ordinary
        )
        XCTAssertEqual(completion, .persisted)
        let delivered = try responseJSON(await bridge.prepareResponseDelivery(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(
            delivered["approvalCommitted"] as? Bool,
            true
        )
        XCTAssertEqual(
            (delivered["error"] as? [String: Any])?["code"] as? Int,
            ProviderResponseError.internalErrorCode
        )
        XCTAssertNil((delivered["error"] as? [String: Any])?["data"])
    }

    func testCompletedResponseRemainsReadableUntilExpiryOrEviction() async throws {
        let fixture = try makeFixture(id: 60)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let completion = await bridge.complete(
            handle: handle,
            response: response(for: fixture.request)
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
        let completion = await bridge.complete(
            handle: handle,
            response: response(for: fixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        let admissionCutoff = clock.now.addingTimeInterval(
            ExtensionBridge.requestTTL +
                ExtensionBridge.admissionDeadlineFutureSkew
        )
        clock.now.addTimeInterval(
            -(ExtensionBridge.responseExpiry - 10 * 60)
        )

        let observer = makeBridge(clock: { self.clock.now })
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
        let observer = makeBridge(clock: { self.clock.now })
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
        let completion = await bridge.complete(
            handle: handle,
            response: response(for: fixture.request)
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
            ingress: makeFixture(id: 731).ingress,
            profileIdentifier: nil
        )).handle
        let delivered = try await recordNativeDelivery(handle: handle)
        XCTAssertEqual(delivered, .persisted)
        guard case .claimed(let claim) = await claimDeliveredNativeExecution(
            in: bridge, handle: handle, approvedAt: clock.now
        ) else { return XCTFail("Expected native claim") }
        defer { claim.approvalClaim.releaseLease() }
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

    func testNativeClaimRequiresAValidExecutionContextAfterRestart()
        async throws {
        let execution = try await makeExecutableNativePermit(id: 732)

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
        let completion = await bridge.complete(
            handle: handle,
            response: response(for: fixture.request)
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
        var failWrites = false
        bridge = makeBridge(
            clock: { self.clock.now },
            atomicWrite: { data, url in
                if failWrites, url.pathExtension == "state" {
                    throw Failure.injectedWrite
                }
                try ApprovalStoreTestPersistence.write(data, url)
            }
        )
        let fixture = try makeFixture(id: 719)
        let admission = try accepted(await bridge.enqueue(
            ingress: fixture.ingress, profileIdentifier: nil
        ))
        let delivered = try await recordNativeDelivery(handle: admission.handle)
        XCTAssertEqual(delivered, .persisted)
        let approvedAt = clock.now
        failWrites = true
        let failed = await claimDeliveredNativeExecution(
            in: bridge, handle: admission.handle, approvedAt: approvedAt
        )
        XCTAssertEqual(failed, .unavailable)
        clock.now.addTimeInterval(60)
        failWrites = false
        guard case .claimed(let claim) = await claimDeliveredNativeExecution(
            in: bridge, handle: admission.handle, approvedAt: approvedAt
        ) else { return XCTFail("Expected the delayed native decision") }
        XCTAssertEqual(claim.approvedAt, approvedAt)
        XCTAssertEqual(claim.executionContext.observedAt, clock.now)
        clock.now.addTimeInterval(10)
        for time in [approvedAt, clock.now] {
            let duplicate = await claimDeliveredNativeExecution(
                in: bridge, handle: admission.handle, approvedAt: time
            )
            XCTAssertEqual(duplicate, .executing)
        }
        let released = await bridge.release(claim: claim.approvalClaim)
        XCTAssertEqual(released, .persisted)
    }

    func testNativeClaimIsProfileScopedAndReleaseIsTerminal() async throws {
        let profile = UUID()
        let fixture = try makeFixture(id: 720)
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
        XCTAssertEqual(nativeClaim.approvedAt, approvedAt)
        let releasedClaim = await bridge.release(claim: nativeClaim.approvalClaim)
        XCTAssertEqual(releasedClaim, .persisted)
        guard case .found(let released) = await bridge.load(handle: handle) else {
            return XCTFail("Expected released snapshot")
        }
        XCTAssertEqual(released.phase, .responded)
        XCTAssertNil(released.nativeApproval)
        let reclaimed = await claimDeliveredNativeExecution(in: bridge, handle: handle, approvedAt: approvedAt)
        XCTAssertEqual(reclaimed, .responded)
    }

    func testCanceledNativeStoreHopCannotCheckpoint() async throws {
        let execution = try await makeExecutableNativePermit(id: 733)

        let recovery = response(for: execution.request)
        let checkpointTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await bridge.prepareBroadcast(
                permit: execution.permit, recoveryResponse: recovery,
                authority: .native(execution.context)
            )
        }
        let checkpoint = await checkpointTask.value
        XCTAssertEqual(checkpoint, .ownershipLost)
        let rollback = await bridge.rollback(permit: execution.permit)
        XCTAssertEqual(rollback, .persisted)
        let received = try responseJSON(await bridge.prepareResponseDelivery(
            id: execution.handle.id, configurationKey: execution.request.configurationKey,
            requestToken: execution.handle.requestToken, profileIdentifier: nil
        ))
        XCTAssertEqual((received["error"] as? [String: Any])?["message"] as? String, Strings.approvalInterrupted)
    }

    func testNativeExecutionRequiresExactReceiptAndValidApprovalTime() async throws {
        let fixture = try makeFixture(id: 734)
        let admission = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil))
        _ = try await recordNativeDelivery(handle: admission.handle)
        guard case .found(let snapshot) = await bridge.load(handle: admission.handle) else {
            return XCTFail("Expected delivered request")
        }
        let receipt = try XCTUnwrap(snapshot.nativeDeliveryReceipt)
        let approvedAt = clock.now
        let original = try Data(contentsOf: defaultProfileURL)
        for mismatch in ["nonce", "runtime", "future", "past", "nan", "infinite"] {
            let timestamp: Date
            switch mismatch {
            case "future": timestamp = approvedAt.addingTimeInterval(1)
            case "past": timestamp = snapshot.createdAt.addingTimeInterval(-1)
            case "nan": timestamp = Date(timeIntervalSince1970: .nan)
            case "infinite": timestamp = Date(timeIntervalSince1970: .infinity)
            default: timestamp = approvedAt
            }
            let claim = await bridge.claimNativeExecution(
                handle: admission.handle,
                nativeDeliveryNonce: mismatch == "nonce" ? .init(value: UUID()) : receipt.nativeDeliveryNonce,
                runtimeInstanceIdentifier: mismatch == "runtime" ? UUID() : receipt.owner.runtimeInstanceIdentifier,
                approvedAt: timestamp
            )
            XCTAssertEqual(claim, .ownershipLost, mismatch)
            XCTAssertEqual(try Data(contentsOf: defaultProfileURL), original, mismatch)
        }
        guard case .claimed(let claimed) = await claimDeliveredNativeExecution(
            in: bridge, handle: admission.handle, approvedAt: approvedAt
        ) else { return XCTFail("Expected exact receipt to claim execution") }
        let fields = try firstStoredNativeApproval("claimed")
        XCTAssertEqual(Set(fields.keys), ["approvedAt", "receipt"])
        let abandoned = await bridge.release(claim: claimed.approvalClaim)
        XCTAssertEqual(abandoned, .persisted)
        let lateClaim = await bridge.claimNativeExecution(
            handle: admission.handle, nativeDeliveryNonce: receipt.nativeDeliveryNonce,
            runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier, approvedAt: approvedAt
        )
        XCTAssertEqual(lateClaim, .responded)
        let fresh = try accepted(await bridge.enqueue(ingress: makeFixture(id: 735).ingress, profileIdentifier: nil))
        XCTAssertNotEqual(fresh.handle.token, admission.handle.token)
        guard case .found(let freshSnapshot) = await bridge.load(handle: fresh.handle),
              case .queued(_, .unowned) = freshSnapshot.state else {
            return XCTFail("A new request must start without authorization")
        }
    }

    func testOrphanedNativeExecutionIsInterruptedWithoutReplay() async throws {
        let execution = try await makeExecutableNativePermit(id: 721)

        execution.permit.releaseLease()
        let observer = makeBridge(clock: { self.clock.now })
        let result = try responseJSON(await observer.prepareResponseDelivery(
            id: execution.handle.id, configurationKey: execution.request.configurationKey,
            requestToken: execution.handle.requestToken, profileIdentifier: nil
        ))
        XCTAssertEqual((result["error"] as? [String: Any])?["message"] as? String, Strings.approvalInterrupted)
        let claimed = await claimDeliveredNativeExecution(in: observer, handle: execution.handle, approvedAt: clock.now)
        XCTAssertEqual(claimed, .responded)
        let lateCompletion = await bridge.complete(
            permit: execution.permit, response: response(for: execution.request),
            authority: .native(execution.context)
        )
        XCTAssertEqual(lateCompletion, .persisted)
        let unchanged = try responseJSON(await observer.prepareResponseDelivery(
            id: execution.handle.id, configurationKey: execution.request.configurationKey,
            requestToken: execution.handle.requestToken, profileIdentifier: nil
        ))
        XCTAssertEqual((unchanged["error"] as? [String: Any])?["message"] as? String, Strings.approvalInterrupted)
    }

    func testOrphanedNativeBroadcastPreservesRecoveryResponse() async throws {
        let execution = try await makeExecutableNativePermit(id: 722)

        let recovery = response(for: execution.request).markingApprovalCommitted()
        let checkpoint = await bridge.prepareBroadcast(
            permit: execution.permit, recoveryResponse: recovery, authority: .native(execution.context)
        )
        XCTAssertEqual(checkpoint, .persisted)
        execution.permit.releaseLease()
        let observer = makeBridge(clock: { self.clock.now })
        let delivered = try responseJSON(await observer.prepareResponseDelivery(
            id: execution.handle.id, configurationKey: execution.request.configurationKey,
            requestToken: execution.handle.requestToken, profileIdentifier: nil
        ))
        XCTAssertEqual(delivered["approvalCommitted"] as? Bool, true)
        XCTAssertEqual(delivered["result"] as? String, recovery.json["result"] as? String)
        XCTAssertNil(delivered["error"])
    }

    func testClearingNativeDeliveryCannotTransferAnActiveClaim() async throws {
        let fixture = try makeFixture(id: 723)
        let admission = try accepted(await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil))
        _ = try await recordNativeDelivery(handle: admission.handle)
        guard case .claimed(let claimed) = await claimDeliveredNativeExecution(
            in: bridge, handle: admission.handle, approvedAt: clock.now
        ), case .found(let snapshot) = await bridge.load(handle: admission.handle) else {
            return XCTFail("Expected active native claim")
        }
        defer { claimed.approvalClaim.releaseLease() }
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

    func testRuntimeIdentityLoadsMismatchedProtocolForRejection() throws {
        let bundleURL = try makeAmbientBundle(name: "Protocol", build: "148")
        let identity = try runtimeIdentity(
            processIdentifier: 791,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 1_789_118_464.514548),
            runtimeProtocolVersion:
                AmbientRuntimeIdentity.currentRuntimeProtocolVersion + 1
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
            withWorkflowVersion: ExtensionBridge.workflowVersion
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
        var uptime: UInt64 = 0
        var isRunning = true
        var verifications = 0
        var quitCount = 0
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in
                    XCTAssertGreaterThanOrEqual(uptime, 1_000_000_000)
                    verifications += 1
                    return true
                },
                helpers: {
                    isRunning
                        ? [
                            self.runtimeHelper(
                                processIdentifier: 798,
                                bundleURL: currentURL,
                                launchDate: Date(timeIntervalSince1970: 9_000),
                                isRunning: { isRunning },
                                requestQuit: {
                                    XCTAssertEqual(verifications, 1)
                                    quitCount += 1
                                    isRunning = false
                                    return true
                                }
                            )
                        ] : []
                },
                identity: { _ in nil },
                uptime: { uptime },
                sleepUntil: { deadline in uptime = max(uptime, deadline) }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        XCTAssertEqual(
            selected,
            .launch(url: currentURL))
        XCTAssertEqual(verifications, 1)
        XCTAssertEqual(quitCount, 1)
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
                        runtimeProtocolVersion: 2
                    )
                )
            })
        var pass = 0
        var verifiedPasses = [Int]()
        var retiredProcesses = [Int32]()
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { url in
                    XCTAssertEqual(url, currentURL)
                    verifiedPasses.append(pass)
                    return true
                },
                helpers: {
                    guard pass < 2 else { return [] }
                    return processIdentifiers[(pass * 2)..<(pass * 2 + 2)].map { processIdentifier in
                        self.runtimeHelper(
                            processIdentifier: processIdentifier,
                            bundleURL: currentURL,
                            launchDate: launchDate,
                            requestQuit: {
                                XCTAssertEqual(verifiedPasses, Array(0...pass))
                                retiredProcesses.append(processIdentifier)
                                return true
                            }
                        )
                    }
                },
                identity: { identities[$0] },
                sleepUntil: { _ in pass += 1 }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        XCTAssertEqual(
            selected,
            .launch(url: currentURL))
        XCTAssertEqual(verifiedPasses, [0, 1])
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
        var uptime: UInt64 = 0
        var quitCount = 0
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    [
                        self.runtimeHelper(
                            processIdentifier: 811,
                            bundleURL: currentURL,
                            launchDate: Date(timeIntervalSince1970: 11_000),
                            requestQuit: {
                                quitCount += 1
                                return false
                            }
                        )
                    ]
                },
                identity: { _ in nil },
                uptime: { uptime },
                sleepUntil: { deadline in uptime = max(uptime, deadline) }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        XCTAssertNil(selected)
        XCTAssertEqual(quitCount, 1)
    }

    @MainActor
    func testNativeAgentResolutionLaunchesAfterLegacyRuntimeExits() async throws {
        let currentURL = try makeAmbientBundle(name: "Legacy", build: "149")
        let launchDate = Date(timeIntervalSince1970: 11_500)
        var uptime: UInt64 = 0
        var isLegacyRunning = true
        var requestCount = 0
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    guard isLegacyRunning else { return [] }
                    return [
                        self.runtimeHelper(
                            processIdentifier: 812,
                            bundleURL: currentURL,
                            launchDate: launchDate,
                            isRunning: { isLegacyRunning },
                            requestQuit: {
                                requestCount += 1
                                isLegacyRunning = false
                                return true
                            }
                        )
                    ]
                },
                identity: { _ in nil },
                uptime: { uptime },
                sleepUntil: { deadline in uptime = max(uptime, deadline) }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        guard let selected,
            case .launch(let selectedURL) = selected
        else { return XCTFail("Expected fresh helper launch") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertEqual(requestCount, 1)
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
        var uptime: UInt64 = 0
        var publishedIdentity: AmbientRuntimeIdentity?
        var isRunning = true
        var identityReadCount = 0
        var quitCount = 0
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    guard isRunning else { return [] }
                    return [
                        self.runtimeHelper(
                            processIdentifier: 813,
                            bundleURL: currentURL,
                            launchDate: launchDate,
                            requestQuit: {
                                quitCount += 1
                                isRunning = false
                                return true
                            }
                        )
                    ]
                },
                identity: { _ in
                    identityReadCount += 1
                    if uptime >= 350_000_000 {
                        publishedIdentity = identity
                    }
                    return publishedIdentity
                },
                uptime: { uptime },
                sleepUntil: { deadline in uptime = max(uptime, deadline) }
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
        XCTAssertGreaterThan(identityReadCount, 5)
        XCTAssertEqual(quitCount, 0)
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
        var uptime: UInt64 = 0
        var boundaryReadCount = 0
        var quitCount = 0
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    [
                        self.runtimeHelper(
                            processIdentifier: 817,
                            bundleURL: currentURL,
                            launchDate: launchDate,
                            requestQuit: {
                                quitCount += 1
                                return true
                            }
                        )
                    ]
                },
                identity: { _ in
                    guard uptime >= 1_000_000_000 else { return nil }
                    boundaryReadCount += 1
                    return boundaryReadCount > 1 ? identity : nil
                },
                uptime: { uptime },
                sleepUntil: { deadline in uptime = max(uptime, deadline) }
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
        XCTAssertEqual(boundaryReadCount, 2)
        XCTAssertEqual(quitCount, 0)
    }

    @MainActor
    func testNativeAgentResolutionPreservesUnknownOtherPath() async throws {
        let currentURL = try makeAmbientBundle(name: "Current", build: "149")
        let otherURL = try makeAmbientBundle(name: "Other Legacy", build: "148")
        var quitCount = 0
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    [
                        self.runtimeHelper(
                            processIdentifier: 814,
                            bundleURL: otherURL,
                            launchDate: Date(timeIntervalSince1970: 11_700),
                            requestQuit: {
                                quitCount += 1
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
        XCTAssertEqual(quitCount, 0)
    }

    @MainActor
    func testUnknownSamePathRetirementPreservesUnknownOtherPath()
        async throws
    {
        let currentURL = try makeAmbientBundle(name: "Current", build: "149")
        let otherURL = try makeAmbientBundle(name: "Other Legacy", build: "148")
        let launchDate = Date(timeIntervalSince1970: 11_800)
        var uptime: UInt64 = 0
        var samePathIsRunning = true
        var samePathQuitCount = 0
        var otherPathQuitCount = 0
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    var result = [
                        self.runtimeHelper(
                            processIdentifier: 815,
                            bundleURL: otherURL,
                            launchDate: launchDate,
                            requestQuit: {
                                otherPathQuitCount += 1
                                return true
                            }
                        )
                    ]
                    if samePathIsRunning {
                        result.append(
                            self.runtimeHelper(
                                processIdentifier: 816,
                                bundleURL: currentURL,
                                launchDate: launchDate,
                                isRunning: { samePathIsRunning },
                                requestQuit: {
                                    samePathQuitCount += 1
                                    samePathIsRunning = false
                                    return true
                                }
                            ))
                    }
                    return result
                },
                identity: { _ in nil },
                uptime: { uptime },
                sleepUntil: { deadline in uptime = max(uptime, deadline) }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        guard let selected,
            case .launch(let selectedURL) = selected
        else { return XCTFail("Expected fresh helper launch") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertEqual(samePathQuitCount, 1)
        XCTAssertEqual(otherPathQuitCount, 0)
    }

    @MainActor
    func testNativeAgentResolutionRetiresIncompatibleRuntimeBeforeLaunch() async throws {
        let currentURL = try makeAmbientBundle(name: "Incompatible", build: "148")
        let launchDate = Date(timeIntervalSince1970: 12_000)
        let identity = try runtimeIdentity(
            processIdentifier: 821,
            bundleURL: currentURL,
            launchDate: launchDate,
            runtimeProtocolVersion: 2
        )
        var isRunning = true
        var quitCount = 0
        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    guard isRunning else { return [] }
                    return [
                        self.runtimeHelper(
                            processIdentifier: 821,
                            bundleURL: currentURL,
                            launchDate: launchDate,
                            isRunning: { isRunning },
                            requestQuit: {
                                quitCount += 1
                                return true
                            }
                        )
                    ]
                },
                identity: { _ in identity },
                sleepUntil: { _ in isRunning = false }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        guard let selected,
            case .launch(let selectedURL) = selected
        else { return XCTFail("Expected launch target") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertEqual(quitCount, 1)
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
            runtimeProtocolVersion: 2
        )
        var incompatibleIsRunning = true
        var quitCount = 0
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
                    if incompatibleIsRunning {
                        result.append(
                            self.runtimeHelper(
                                processIdentifier: 832,
                                bundleURL: currentURL,
                                launchDate: launchDate,
                                isRunning: { incompatibleIsRunning },
                                requestQuit: {
                                    quitCount += 1
                                    return true
                                }
                            ))
                    }
                    return result
                },
                identity: { processIdentifier in
                    processIdentifier == 831 ? compatible : incompatible
                },
                sleepUntil: { _ in incompatibleIsRunning = false }
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
        XCTAssertEqual(quitCount, 1)
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
            runtimeProtocolVersion:
                AmbientRuntimeIdentity.currentRuntimeProtocolVersion,
            supportedWorkflowVersions: [ExtensionBridge.workflowVersion],
            launchedAt: launchDate
        )
        var isRunning = true
        var quitCount = 0

        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    guard isRunning else { return [] }
                    return [
                        self.runtimeHelper(
                            processIdentifier: 833,
                            bundleURL: currentURL,
                            launchDate: launchDate,
                            isRunning: { isRunning },
                            requestQuit: {
                                quitCount += 1
                                return true
                            }
                        )
                    ]
                },
                identity: { _ in identity },
                sleepUntil: { _ in isRunning = false }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: currentURL)),
            deadline: UInt64.max
        )

        guard let selected,
            case .launch(let selectedURL) = selected
        else { return XCTFail("Expected a fresh helper launch") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertEqual(quitCount, 1)
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
            runtimeProtocolVersion: 2
        )
        var quitCount = 0

        let selected = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in true },
                helpers: {
                    [
                        self.runtimeHelper(
                            processIdentifier: 835,
                            bundleURL: currentURL,
                            launchDate: launchDate,
                            requestQuit: {
                                quitCount += 1
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
        XCTAssertEqual(quitCount, 1)
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
            let status = await NativeAgentLauncher(dependencies: launcherTestDependencies(
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
                        runtimeProtocolVersion: original.runtimeProtocolVersion,
                        supportedWorkflowVersions: original.supportedWorkflowVersions,
                        launchedAt: original.launchedAt
                    )
                }
            )).status(
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
    func testRuntimeConfirmationRechecksIdentityAfterCodeVerification() async throws {
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
        var verifications = 0
        let confirmed = await NativeAgentLauncher(dependencies: launcherTestDependencies(
            validate: { _ in
                verifications += 1
                await Task.yield()
                identity = replacement
                return true
            },
            helpers: { [helper] },
            identity: { _ in identity }
        )).isConfirmed(
            try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: bundleURL)),
            deadline: UInt64.max
        )

        XCTAssertFalse(confirmed)
        XCTAssertEqual(verifications, 1)

        identity = original
        let status = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in
                verifications += 1
                await Task.yield()
                identity = replacement
                return true
            },
                helper: { pid in
                XCTAssertEqual(pid, original.processIdentifier)
                return helper
            },
                identity: { _ in identity }
            )).status(
                owner: try XCTUnwrap(original.nativeDeliveryOwner),
                expected: .init(url: bundleURL, version: original.version)
            )
        guard case .unidentified = status else {
            return XCTFail("Changed receipt owner must not receive delivery")
        }
        XCTAssertEqual(verifications, 2)
    }

    @MainActor
    func testRuntimeVerificationRejectsAnInstalledVersionDifferentFromCapturedVersion() async throws {
        let bundleURL = try makeAmbientBundle(name: "Updated Since Capture", build: "149")
        let launchDate = Date(timeIntervalSince1970: 14_150)
        let identity = AmbientRuntimeIdentity(
            instanceIdentifier: UUID(),
            processIdentifier: 848,
            bundlePath: bundleURL.path,
            version: .init(marketing: "1.0.99", build: "148"),
            runtimeProtocolVersion: AmbientRuntimeIdentity.currentRuntimeProtocolVersion,
            supportedWorkflowVersions: [ExtensionBridge.workflowVersion],
            launchedAt: launchDate
        )
        let helper = runtimeHelper(
            processIdentifier: identity.processIdentifier,
            bundleURL: bundleURL,
            launchDate: launchDate
        )
        var verifications = 0
        let validate: (URL) async -> Bool = { url in
            XCTAssertEqual(url, bundleURL)
            verifications += 1
            return true
        }
        let confirmed = await NativeAgentLauncher(dependencies: launcherTestDependencies(
            validate: validate,
            helpers: { [helper] },
            identity: { _ in identity }
        )).isConfirmed(
            .init(url: bundleURL, version: identity.version),
            deadline: UInt64.max
        )
        XCTAssertFalse(confirmed)
        XCTAssertEqual(verifications, 1)

        let status = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: validate,
                helper: { pid in
                ([helper]).first { $0.processIdentifier == pid }
            },
                identity: { _ in identity }
            )).status(
                owner: try XCTUnwrap(identity.nativeDeliveryOwner),
                expected: .init(url: bundleURL, version: identity.version)
            )
        guard case .unidentified = status else {
            return XCTFail("An updated installed bundle must invalidate captured compatibility")
        }
        XCTAssertEqual(verifications, 2)
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

        let status = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { $0 == expectedURL },
                helper: { pid in
                ([self.runtimeHelper(
                    processIdentifier: 836,
                    bundleURL: otherURL,
                    launchDate: Date(timeIntervalSince1970: 13_700)
                )]).first { $0.processIdentifier == pid }
            },
                identity: { _ in nil }
            )).status(
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

        let status = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { $0 == expectedURL },
                helper: { pid in
                ([self.runtimeHelper(
                    processIdentifier: receipt.owner.processIdentifier,
                    bundleURL: expectedURL,
                    launchDate: receipt.owner.processStartDate
                )]).first { $0.processIdentifier == pid }
            },
                identity: { _ in nil }
            )).status(
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
        var uptime: UInt64 = 0
        var helperReads = 0
        let target = await NativeAgentLauncher(dependencies: launcherTestDependencies(
                validate: { _ in
                    XCTFail("An expired resolution must not validate a helper")
                    return false
                },
                helpers: {
                    helperReads += 1
                    uptime = 50_000_000
                    return []
                },
                identity: { _ in nil },
                uptime: {
                    uptime
                },
                sleepUntil: { _ in XCTFail("An expired resolution must not sleep") }
            )).resolveTarget(
            expected: try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: helperURL)),
            deadline: 50_000_000
        )
        XCTAssertNil(target)
        XCTAssertEqual(helperReads, 1)
    }

    func testMaintenanceStopsAtStoreLockContention() async throws {
        let profileIdentifier = UUID()
        let fixture = try makeFixture(id: 81)
        let handle = try accepted(await bridge.enqueue(
            ingress: try profileFixture(fixture, profileIdentifier: profileIdentifier).ingress, profileIdentifier: profileIdentifier
        )).handle
        let completed = await bridge.complete(handle: handle, response: response(for: fixture.request))
        XCTAssertEqual(completed, .persisted)
        let url = profileURL(profileIdentifier)
        let original = try Data(contentsOf: url)
        clock.now.addTimeInterval(ExtensionBridge.responseExpiry)
        try await CrossProcessLockTestFixture.withHeldLock(
            at: rootURL.appendingPathComponent("bridge-v8.lock"),
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

    func testSeparateProcessStoreLockFencesAccess() async throws {
        let fixture = try makeFixture(id: 80)
        let readyURL = rootURL.appendingPathComponent("holder-ready")
        let lockURL = rootURL.appendingPathComponent("bridge-v8.lock")
        try await CrossProcessLockTestFixture.withHeldLock(
            at: lockURL,
            readyURL: readyURL
        ) {
            guard case .unavailable = await self.bridge.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: nil
            ) else { throw Failure.expectedValue }
        }
    }
    #endif

    private func assertAdmissionRetryRequiresSynchronization(
        original: Fixture,
        retry: Fixture,
        admissionKind: ExtensionBridge.AdmissionKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        var writes = 0
        var synchronizationAttempts = 0
        var failSynchronization = true
        let writer = makeBridge(
            clock: { self.clock.now },
            atomicWrite: { data, url in
                writes += 1
                try data.write(to: url, options: .atomic)
                throw Failure.injectedWrite
            },
            synchronizePublishedFile: { url in
                synchronizationAttempts += 1
                XCTAssertEqual(url, self.defaultProfileURL, file: file, line: line)
                if failSynchronization { throw Failure.injectedWrite }
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
        XCTAssertEqual(synchronizationAttempts, 3, file: file, line: line)
        failSynchronization = false
        let recovered = try accepted(await writer.enqueue(
            ingress: retry.ingress,
            profileIdentifier: nil
        ), file: file, line: line)
        XCTAssertEqual(recovered.admissionKind, admissionKind, file: file, line: line)
        XCTAssertEqual(recovered.handle, snapshot.handle, file: file, line: line)
        XCTAssertEqual(recovered.nativeDeliveryNonce, snapshot.nativeDeliveryNonce, file: file, line: line)
        XCTAssertEqual(recovered.revisions, original.ingress.authority.revisions, file: file, line: line)
        XCTAssertTrue(recovered.approvalRequired, file: file, line: line)
        XCTAssertEqual(synchronizationAttempts, 4, file: file, line: line)
        XCTAssertEqual(writes, 1, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: defaultProfileURL), originalData, file: file, line: line)
    }

    private func makeBridge(
        clock: @escaping () -> Date = Date.init,
        atomicWrite: @escaping ExtensionRequestFileStore.AtomicWrite =
            ApprovalStoreTestPersistence.write,
        synchronizePublishedFile: @escaping (URL) throws -> Void =
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
        runtimeProtocolVersion: Int =
            AmbientRuntimeIdentity.currentRuntimeProtocolVersion
    ) throws -> AmbientRuntimeIdentity {
        AmbientRuntimeIdentity(
            instanceIdentifier: UUID(),
            processIdentifier: processIdentifier,
            bundlePath: bundleURL.standardizedFileURL.path,
            version: try XCTUnwrap(
                AmbientRuntimeIdentity.bundleVersion(at: bundleURL)
            ),
            runtimeProtocolVersion: runtimeProtocolVersion,
            supportedWorkflowVersions: [ExtensionBridge.workflowVersion],
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
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.ingress.canonicalData) as? [String: Any])
        raw["authority"] = try authorityVersion(fixture.request.configurationKey, profileIdentifier: profileIdentifier).json
        if fixture.ingress.replayOnly { raw["replayOnly"] = true }
        return try authorityFixture(raw)
    }

    private func authorityVersion(_ configurationKey: String, profileIdentifier: UUID? = nil) throws -> ExtensionBridge.AuthorityVersion {
        let key = (profileIdentifier?.uuidString ?? "default") + configurationKey
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL,
            dependencies: .init(clock: { self.clock.now }, atomicWrite: ApprovalStoreTestPersistence.write))
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
        favicon: String = "",
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
            "favicon": favicon,
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
        return await store.claimNativeExecution(
            handle: handle,
            nativeDeliveryNonce: receipt.nativeDeliveryNonce,
            runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier,
            approvedAt: approvedAt
        )
    }

    private func makeExecutableNativePermit(
        id: Int
    ) async throws -> (
        request: SafariRequest,
        handle: ExtensionBridge.Handle,
        context: ExtensionBridge.NativeExecutionContext,
        permit: ExtensionBridge.ExecutionPermit
    ) {
        let fixture = try makeFixture(id: id)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let delivered = try await recordNativeDelivery(handle: handle)
        XCTAssertEqual(delivered, .persisted)
        let nativeClaim: ExtensionBridge.NativeExecutionClaim
        switch await claimDeliveredNativeExecution(in: bridge, handle: handle, approvedAt: clock.now) {
        case .claimed(let value):
            nativeClaim = value
        case .ownershipLost, .executing, .responded, .missing, .unavailable:
            throw Failure.expectedValue
        }
        let permit = try executionPermit(await bridge.begin(
            claim: nativeClaim.approvalClaim
        ))
        return (
            fixture.request,
            handle,
            nativeClaim.executionContext,
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
            "favicon": "",
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

    private func manualSwitchRequests(
        _ result: ExtensionBridge.ManualSwitchRequestsResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [ExtensionBridge.ManualSwitchRequest] {
        guard case .available(let page) = result else {
            XCTFail("Expected manual switch requests", file: file, line: line)
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

    private func executionPermit(
        _ result: ExtensionBridge.BeginExecutionResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ExtensionBridge.ExecutionPermit {
        guard case .began(let permit) = result else {
            XCTFail("Expected execution permit", file: file, line: line)
            throw Failure.expectedValue
        }
        return permit
    }

    private var largeResponseResult: String {
        String(repeating: "a", count: ExtensionBridge.maximumPayloadBytes - 1024)
    }

    private func largeResponse(for request: SafariRequest) -> ResponseToExtension {
        ResponseToExtension(
            for: request,
            payload: .result(.string(largeResponseResult))
        )
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
            let completion = await bridge.complete(
                handle: handle,
                response: largeResponse(for: fixture.request)
            )
            XCTAssertEqual(completion, .persisted)
            completed.append((fixture, handle))
        }
        XCTFail("Expected bounded completed-response byte capacity")
        throw Failure.expectedValue
    }

    private func response(for request: SafariRequest) -> ResponseToExtension {
        if case .unknown = request.body {
            return ResponseToExtension(for: request, payload: .result(.null), mutation: .accounts([]))
        }
        return ResponseToExtension(
            for: request,
            payload: .result(.string("0xsigned"))
        )
    }

    private func ambiguousSubmissionResponse(
        for request: SafariRequest,
        transactionHash: String
    ) -> ResponseToExtension {
        ResponseToExtension(
            for: request,
            payload: .error(.init(
                message: Strings.transactionSubmissionStatusUnknown,
                code: ProviderResponseError.transactionSubmissionUnknownCode,
                context: .transactionHash(transactionHash)
            ))
        )
    }

    private func oversizedCommittedError(
        for request: SafariRequest
    ) -> ResponseToExtension {
        ResponseToExtension(
            for: request,
            payload: .error(.init(
                message: String(repeating: "x", count: ExtensionBridge.maximumPayloadBytes),
                code: ProviderResponseError.internalErrorCode
            ))
        ).markingApprovalCommitted()
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

    private func profileURL(_ profileIdentifier: UUID?) -> URL {
        let name = profileIdentifier?.uuidString.lowercased() ?? "default"
        return rootURL
            .appendingPathComponent("profiles-v8", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("state")
    }

    private func operationLockURL(_ handle: ExtensionBridge.Handle) -> URL {
        let profile = handle.profileIdentifier?.uuidString.lowercased() ?? "default"
        return rootURL
            .appendingPathComponent("operation-locks-v8", isDirectory: true)
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
        let observer = makeBridge(clock: { self.clock.now })
        guard case .unavailable = await observer.list(profileIdentifier: nil) else {
            return XCTFail("Expected malformed profile to be unavailable", file: file, line: line)
        }
        guard case .unavailable = await observer.enqueue(
            ingress: try makeFixture(id: 734).ingress,
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
