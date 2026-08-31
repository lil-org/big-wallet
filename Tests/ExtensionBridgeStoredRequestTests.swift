// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

final class ExtensionBridgeStoredRequestTests: XCTestCase {
    private enum Failure: Error { case expectedValue, injectedWrite }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
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
            "extension-bridge-v5-\(UUID().uuidString)",
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

    func testWorkflowPolicyIsV3AndPrivateBrowsingRemainsUnsupported() async throws {
        XCTAssertEqual(ExtensionBridge.workflowVersion, 3)
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

    func testLostEnqueueReplyDeduplicatesTheExactAttempt() async throws {
        final class WriteControl {
            var shouldThrow = true
            func write(_ data: Data, to url: URL) throws {
                try ExtensionRequestFileStore.defaultAtomicWrite(data, url)
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

        guard case .unavailable = await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected uncertain first enqueue") }
        let retry = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let repeated = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(retry.handle, repeated.handle)
        guard case .available(let snapshots) = await bridge.list(
            profileIdentifier: nil
        ) else { return XCTFail("Expected list") }
        XCTAssertEqual(snapshots.count, 1)
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
            enqueueAttempt: attempt,
            favicon: "https://wallet.example/first.png"
        )
        let changedFavicon = try makeFixture(
            id: 4,
            enqueueAttempt: attempt,
            favicon: "https://wallet.example/second.png"
        )
        let changedRevisions = try makeFixture(
            id: 4,
            enqueueAttempt: attempt,
            revisions: ["ethereum": 1, "solana": 0]
        )
        let admitted = try accepted(await bridge.enqueue(
            ingress: original.ingress,
            profileIdentifier: nil
        ))
        let faviconRetry = try accepted(await bridge.enqueue(
            ingress: changedFavicon.ingress,
            profileIdentifier: nil
        ))
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
        XCTAssertEqual(revisionRetry.handle, admitted.handle)
        XCTAssertEqual(revisionRetry.revisions, admitted.revisions)
        XCTAssertEqual(admitted.revisions.ethereum, 0)
    }

    func testStoredRequestRevisionMismatchFailsClosed() async throws {
        _ = try accepted(await bridge.enqueue(
            ingress: try makeFixture(id: 5).ingress,
            profileIdentifier: nil
        ))
        try mutateFirstStoredRecord { record in
            var state = try XCTUnwrap(record["state"] as? [String: Any])
            var pending = try XCTUnwrap(state["pending"] as? [String: Any])
            let requestData = try XCTUnwrap(pending["request"] as? Data)
            var request = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestData) as? [String: Any]
            )
            request["revisions"] = ["ethereum": 1, "solana": 0]
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
            record["revisions"] = ["ethereum": -1, "solana": 0]
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

    func testRetainedCapacityProtectsCompletedDeduplicationWindowThenEvicts() async throws {
        var retained = [(
            fixture: Fixture,
            handle: ExtensionBridge.Handle,
            revisions: ExtensionBridge.ProviderRevisions
        )]()
        for id in 0..<ExtensionBridge.maximumRetainedRequests {
            let fixture = try makeFixture(id: id, host: "\(id).example")
            let enqueued = try accepted(await bridge.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: nil
            ))
            let completion = await bridge.complete(
                handle: enqueued.handle,
                response: response(for: fixture.request)
            )
            XCTAssertEqual(completion, .persisted)
            retained.append((fixture, enqueued.handle, enqueued.revisions))
        }

        let oldest = retained[0]
        let changedRevisions = try makeFixture(
            id: oldest.fixture.request.id,
            host: oldest.fixture.request.host,
            admissionDeadline: oldest.fixture.request.admissionDeadline,
            revisions: ["ethereum": 9, "solana": 4]
        )
        clock.now.addTimeInterval(
            ExtensionBridge.requestTTL +
                ExtensionBridge.admissionDeadlineFutureSkew - 1
        )
        let retry = try accepted(await bridge.enqueue(
            ingress: changedRevisions.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(retry.handle, oldest.handle)
        XCTAssertFalse(retry.approvalRequired)
        XCTAssertEqual(retry.revisions, oldest.revisions)

        let lockURL = operationLockURL(oldest.handle)
        try Data().write(to: lockURL)
        let replacementFixture = try makeFixture(
            id: 1000,
            host: "replacement.example"
        )
        guard case .rejected = await bridge.enqueue(
            ingress: replacementFixture.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected protected capacity rejection") }
        guard case .found = await bridge.load(handle: oldest.handle) else {
            return XCTFail("Expected protected completion retention")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))

        clock.now.addTimeInterval(1)
        let boundaryRetry = try accepted(await bridge.enqueue(
            ingress: changedRevisions.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(boundaryRetry.handle, oldest.handle)
        XCTAssertFalse(boundaryRetry.approvalRequired)

        let replacement = try accepted(await bridge.enqueue(
            ingress: replacementFixture.ingress,
            profileIdentifier: nil
        ))
        guard case .missing = await bridge.load(handle: oldest.handle) else {
            return XCTFail("Expected oldest completed response eviction")
        }
        guard case .found = await bridge.load(handle: retained[1].handle) else {
            return XCTFail("Expected later completed response retention")
        }
        guard case .found = await bridge.load(handle: replacement.handle) else {
            return XCTFail("Expected replacement admission")
        }
        guard case .missing = await bridge.readResponse(
            id: oldest.handle.id,
            configurationKey: oldest.fixture.request.configurationKey,
            requestToken: oldest.handle.requestToken,
            profileIdentifier: nil
        ) else { return XCTFail("Expected evicted response to remain unavailable") }
        let evictedClaim = await bridge.claim(handle: oldest.handle)
        XCTAssertEqual(evictedClaim, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))

        guard case .expired = await bridge.enqueue(
            ingress: oldest.fixture.ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected evicted retry to expire") }
    }

    func testRetainedCapacityReservesFourSlotsAcrossSchemefulOrigins() async throws {
        var primary = [(fixture: Fixture, handle: ExtensionBridge.Handle)]()
        for id in 0..<ExtensionBridge.maximumRetainedRequestsPerOrigin {
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
            primary.append((fixture, handle))
        }

        let exactRetry = try accepted(await bridge.enqueue(
            ingress: primary[0].fixture.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(exactRetry.handle, primary[0].handle)
        XCTAssertFalse(exactRetry.approvalRequired)

        guard case .rejected = await bridge.enqueue(
            ingress: try makeFixture(id: 1000).ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected protected origin capacity rejection") }

        var secondaryHandles = [ExtensionBridge.Handle]()
        for id in 100..<104 {
            let fixture = try makeFixture(
                id: id,
                configurationKey: "http://wallet.example"
            )
            let handle = try accepted(await bridge.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: nil
            )).handle
            let completion = await bridge.complete(
                handle: handle,
                response: response(for: fixture.request)
            )
            XCTAssertEqual(completion, .persisted)
            secondaryHandles.append(handle)
        }

        guard case .rejected = await bridge.enqueue(
            ingress: try makeFixture(
                id: 104,
                configurationKey: "http://wallet.example"
            ).ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected protected global capacity rejection") }

        clock.now.addTimeInterval(
            ExtensionBridge.requestTTL +
                ExtensionBridge.admissionDeadlineFutureSkew
        )
        let replacement = try makeFixture(id: 1001)
        _ = try accepted(await bridge.enqueue(
            ingress: replacement.ingress,
            profileIdentifier: nil
        ))

        guard case .missing = await bridge.load(handle: primary[0].handle) else {
            return XCTFail("Expected oldest same-origin completion eviction")
        }
        for handle in secondaryHandles {
            guard case .found = await bridge.load(handle: handle) else {
                return XCTFail("Expected other schemeful origin retention")
            }
        }
    }

    func testCompletedChurnRemainsBoundedAcrossProtectedWindows() async throws {
        var firstWave = [(fixture: Fixture, handle: ExtensionBridge.Handle)]()
        for id in 0..<ExtensionBridge.maximumRetainedRequests {
            let fixture = try makeFixture(id: id, host: "churn-\(id).example")
            let handle = try accepted(await bridge.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: nil
            )).handle
            let completion = await bridge.complete(
                handle: handle,
                response: response(for: fixture.request)
            )
            XCTAssertEqual(completion, .persisted)
            firstWave.append((fixture, handle))
        }
        guard case .rejected = await bridge.enqueue(
            ingress: try makeFixture(id: 1000, host: "protected.example").ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected protected churn rejection") }

        clock.now.addTimeInterval(
            ExtensionBridge.requestTTL +
                ExtensionBridge.admissionDeadlineFutureSkew
        )
        var secondWave = [(fixture: Fixture, handle: ExtensionBridge.Handle)]()
        let secondWaveStart = ExtensionBridge.maximumRetainedRequests
        for id in secondWaveStart..<(secondWaveStart * 2) {
            let fixture = try makeFixture(id: id, host: "churn-\(id).example")
            let handle = try accepted(await bridge.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: nil
            )).handle
            let completion = await bridge.complete(
                handle: handle,
                response: response(for: fixture.request)
            )
            XCTAssertEqual(completion, .persisted)
            secondWave.append((fixture, handle))
        }
        guard case .rejected = await bridge.enqueue(
            ingress: try makeFixture(id: 1001, host: "protected.example").ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected second protected churn rejection") }

        for item in firstWave {
            guard case .missing = await bridge.load(handle: item.handle) else {
                return XCTFail("Expected old completion eviction")
            }
            guard case .expired = await bridge.enqueue(
                ingress: item.fixture.ingress,
                profileIdentifier: nil
            ) else { return XCTFail("Expected evicted retry to expire") }
        }

        let profile = try storedProfile()
        let records = try XCTUnwrap(profile["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, ExtensionBridge.maximumRetainedRequests)
        for item in secondWave {
            guard case .found(let snapshot) = await bridge.load(handle: item.handle) else {
                return XCTFail("Expected recent completion retention")
            }
            XCTAssertEqual(snapshot.phase, .responded)
        }
    }

    func testCompletedEvictionNeverRemovesActiveRecords() async throws {
        var oldestCompletedHandle: ExtensionBridge.Handle?
        for id in 3..<ExtensionBridge.maximumRetainedRequests {
            let fixture = try makeFixture(id: id, host: "completed-\(id).example")
            let handle = try accepted(await bridge.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: nil
            )).handle
            let completion = await bridge.complete(
                handle: handle,
                response: response(for: fixture.request)
            )
            XCTAssertEqual(completion, .persisted)
            if oldestCompletedHandle == nil { oldestCompletedHandle = handle }
        }
        clock.now.addTimeInterval(
            ExtensionBridge.requestTTL +
                ExtensionBridge.admissionDeadlineFutureSkew
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
        let recovery = ambiguousSubmissionResponse(
            for: prepared.request,
            transactionHash: "0x1234"
        )
        let preparation = await bridge.prepareBroadcast(
            permit: permit,
            recoveryResponse: recovery
        )
        XCTAssertEqual(preparation, .persisted)

        _ = try accepted(await bridge.enqueue(
            ingress: try makeFixture(id: 1000, host: "replacement.example").ingress,
            profileIdentifier: nil
        ))
        guard case .missing = await bridge.load(
            handle: try XCTUnwrap(oldestCompletedHandle)
        ) else { return XCTFail("Expected eligible completion eviction") }

        guard case .found(let pendingSnapshot) = await bridge.load(handle: pendingHandle) else {
            return XCTFail("Expected pending request to remain retained")
        }
        XCTAssertEqual(pendingSnapshot.phase, .queued)
        let repeatedClaim = await bridge.claim(handle: claimedHandle)
        XCTAssertEqual(repeatedClaim, .executing)
        guard case .found(let claimedSnapshot) = await bridge.load(handle: claimedHandle) else {
            return XCTFail("Expected claimed execution to remain retained")
        }
        XCTAssertEqual(claimedSnapshot.phase, .approving)
        guard case .found(let preparedSnapshot) = await bridge.load(handle: preparedHandle) else {
            return XCTFail("Expected prepared broadcast to remain retained")
        }
        XCTAssertEqual(preparedSnapshot.phase, .approving)
        guard case .pending = await bridge.readResponse(
            id: preparedHandle.id,
            configurationKey: prepared.request.configurationKey,
            requestToken: preparedHandle.requestToken,
            profileIdentifier: nil
        ) else { return XCTFail("Expected prepared broadcast ownership") }

        let release = await bridge.release(claim: claim)
        XCTAssertEqual(release, .persisted)
        let completion = await bridge.complete(permit: permit, response: recovery)
        XCTAssertEqual(completion, .persisted)
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
        let rejection = try responseJSON(await bridge.readResponse(
            id: pendingHandle.id,
            configurationKey: pending.request.configurationKey,
            requestToken: pendingHandle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(rejection["errorCode"] as? Int, 4001)
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
        let rejection = try responseJSON(await bridge.readResponse(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(rejection["errorCode"] as? Int, 4001)
        XCTAssertNil(rejection["result"])
    }

    func testProfilesAreIndependent() async throws {
        let fixture = try makeFixture(id: 30)
        let firstProfile = UUID()
        let secondProfile = UUID()
        let first = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: firstProfile
        )).handle
        let second = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: secondProfile
        )).handle
        XCTAssertNotEqual(first, second)
        let completion = await bridge.complete(
            handle: first,
            response: response(for: fixture.request)
        )
        XCTAssertEqual(completion, .persisted)
        guard case .response = await bridge.readResponse(
            id: first.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: first.requestToken,
            profileIdentifier: firstProfile
        ) else { return XCTFail("Expected first profile response") }
        guard case .pending = await bridge.readResponse(
            id: second.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: second.requestToken,
            profileIdentifier: secondProfile
        ) else { return XCTFail("Expected second profile pending") }
    }

    func testMaintenanceRemovesExpiredInactiveProfile() async throws {
        let inactiveProfile = UUID()
        let fixture = try makeFixture(id: 31)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
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
        guard case .available = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected default profile maintenance")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: inactiveURL.path))
    }

    func testEnqueueAndResponsePollingDoNotSweepExpiredInactiveProfile() async throws {
        let inactiveProfile = UUID()
        let fixture = try makeFixture(id: 35)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
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
            guard case .pending = await bridge.readResponse(
                id: pollingHandle.id,
                configurationKey: pollingFixture.request.configurationKey,
                requestToken: pollingHandle.requestToken,
                profileIdentifier: nil
            ) else { return XCTFail("Expected pending polled response") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: inactiveURL.path))

        guard case .available = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected list maintenance")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: inactiveURL.path))
    }

    func testMaintenanceRemovesAlreadyEmptyInactiveProfile() async throws {
        let inactiveProfile = UUID()
        let inactiveURL = profileURL(inactiveProfile)
        _ = try accepted(await bridge.enqueue(
            ingress: try makeFixture(id: 34).ingress,
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

        guard case .available = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected default profile maintenance")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: inactiveURL.path))
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
        XCTAssertEqual(try Data(contentsOf: inactiveURL), corrupt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanLockURL.path))
    }

    func testMaintenanceSweepIsBoundedAndUsesDiskCursorAcrossStores() async throws {
        let batchSize = ExtensionRequestFileStore.profileSweepBatchSize
        let profileCount = batchSize * 2 + 1
        let firstBridge = try XCTUnwrap(bridge)
        var heldClaims = [ExtensionBridge.ApprovalClaim]()
        defer { heldClaims.forEach { $0.releaseLease() } }
        var profileURLs = [URL]()
        for index in 0..<profileCount {
            let profileIdentifier = try XCTUnwrap(UUID(uuidString: String(
                format: "00000000-0000-0000-0000-%012x",
                index + 1
            )))
            let fixture = try makeFixture(id: 200 + index)
            let handle = try accepted(await firstBridge.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: profileIdentifier
            )).handle
            if index < batchSize * 2 {
                heldClaims.append(try approvalClaim(
                    await firstBridge.claim(handle: handle)
                ))
            } else {
                let completion = await firstBridge.complete(
                    handle: handle,
                    response: response(for: fixture.request)
                )
                XCTAssertEqual(completion, .persisted)
            }
            profileURLs.append(profileURL(profileIdentifier))
        }

        clock.now.addTimeInterval(ExtensionBridge.responseExpiry)
        guard case .available = await firstBridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected first maintenance batch")
        }
        XCTAssertEqual(
            profileURLs.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }.count,
            profileCount
        )

        let secondBridge = makeBridge(clock: { self.clock.now })
        guard case .available = await secondBridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected restarted maintenance batch")
        }
        XCTAssertEqual(
            profileURLs.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }.count,
            profileCount
        )

        guard case .available = await firstBridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected authoritative cursor maintenance")
        }
        XCTAssertEqual(
            profileURLs.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }.count,
            profileCount - 1
        )
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

        guard case .available = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected best-effort maintenance")
        }
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

        guard case .available = await bridge.list(profileIdentifier: nil) else {
            return XCTFail("Expected symlink to be isolated")
        }
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
        let response = try responseJSON(await observer.readResponse(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(response["errorCode"] as? Int, 4001)
    }

    func testReleasedClaimAfterDeadlineBecomesRetainedRejection() async throws {
        let fixture = try makeFixture(id: 95)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        clock.now.addTimeInterval(ExtensionBridge.requestTTL)

        let release = await bridge.release(claim: claim)
        XCTAssertEqual(release, .ownershipLost)
        guard case .found(let released) = await bridge.load(handle: handle) else {
            return XCTFail("Expected retained release rejection")
        }
        XCTAssertEqual(released.phase, .responded)
        let response = try responseJSON(await bridge.readResponse(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(response["errorCode"] as? Int, 4001)
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

    func testHeldClaimSurvivesPendingDeadline() async throws {
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

        _ = try executionPermit(await bridge.begin(claim: claim))
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
            recoveryResponse: recovery
        )
        XCTAssertEqual(preparation, .persisted)
        clock.now.addTimeInterval(ExtensionBridge.requestTTL * 2)

        guard case .pending = await bridge.readResponse(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ) else { return XCTFail("Expected held prepared broadcast") }

        permit?.releaseLease()
        permit = nil

        let delivered = try responseJSON(await bridge.readResponse(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(
            delivered["errorCode"] as? Int,
            ProviderResponseError.transactionSubmissionUnknownCode
        )
    }

    func testCheckpointAfterPendingDeadlineRemainsOwned() async throws {
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
            recoveryResponse: recovery
        )
        XCTAssertEqual(preparation, .persisted)
        guard case .pending = await bridge.readResponse(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ) else { return XCTFail("Expected checkpoint ownership") }
        permit?.releaseLease()
        permit = nil
        _ = try responseJSON(await bridge.readResponse(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
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
            recoveryResponse: recovery
        )
        XCTAssertEqual(preparation, .persisted)
        permit?.releaseLease()
        permit = nil
        claim = nil

        let observer = makeBridge(clock: { self.clock.now })
        let delivered = try responseJSON(await observer.readResponse(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(
            delivered["errorCode"] as? Int,
            ProviderResponseError.transactionSubmissionUnknownCode
        )
        XCTAssertNotNil(delivered["errorDataJSON"] as? String)
        let retry = try accepted(await observer.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        XCTAssertEqual(retry.handle, handle)
        XCTAssertFalse(retry.approvalRequired)
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
            recoveryResponse: recovery
        )
        XCTAssertEqual(preparation, .persisted)
        let oversized = oversizedCommittedError(for: fixture.request)

        let completion = await bridge.complete(permit: permit, response: oversized)
        XCTAssertEqual(completion, .persisted)
        let delivered = try responseJSON(await bridge.readResponse(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(
            delivered[ExtensionBridge.approvalCommittedKey] as? Bool,
            true
        )
        XCTAssertEqual(
            delivered["errorCode"] as? Int,
            ProviderResponseError.transactionSubmissionUnknownCode
        )
        XCTAssertEqual(
            delivered["errorDataJSON"] as? String,
            "{\"transactionHash\":\"0x1234\"}"
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

        let completion = await bridge.complete(permit: permit, response: oversized)
        XCTAssertEqual(completion, .persisted)
        let delivered = try responseJSON(await bridge.readResponse(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(
            delivered[ExtensionBridge.approvalCommittedKey] as? Bool,
            true
        )
        XCTAssertEqual(
            delivered["errorCode"] as? Int,
            ProviderResponseError.internalErrorCode
        )
        XCTAssertNil(delivered["errorDataJSON"])
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
        let first = try responseJSON(await bridge.readResponse(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        let repeated = try responseJSON(await bridge.readResponse(
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
        _ = try responseJSON(await observer.readResponse(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        clock.now.addTimeInterval(ExtensionBridge.responseExpiry)
        _ = try responseJSON(await observer.readResponse(
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

    func testLargeBackwardClockCorrectionFailsClosedAtCompletedCapacity() async throws {
        var oldest: (fixture: Fixture, handle: ExtensionBridge.Handle)?
        for id in 0..<ExtensionBridge.maximumRetainedRequests {
            let fixture = try makeFixture(id: id, host: "future-\(id).example")
            let handle = try accepted(await bridge.enqueue(
                ingress: fixture.ingress,
                profileIdentifier: nil
            )).handle
            let completion = await bridge.complete(
                handle: handle,
                response: response(for: fixture.request)
            )
            XCTAssertEqual(completion, .persisted)
            if oldest == nil { oldest = (fixture, handle) }
        }
        let retained = try XCTUnwrap(oldest)
        clock.now.addTimeInterval(-ExtensionBridge.responseExpiry * 2)
        let observer = makeBridge(clock: { self.clock.now })

        guard case .rejected = await observer.enqueue(
            ingress: try makeFixture(id: 1000, host: "corrected.example").ingress,
            profileIdentifier: nil
        ) else { return XCTFail("Expected corrected-clock capacity rejection") }
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
        XCTAssertEqual(
            records.count,
            ExtensionBridge.maximumRetainedRequests
        )
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

    #if os(macOS)
    func testSeparateProcessStoreLockFencesAccess() async throws {
        let fixture = try makeFixture(id: 80)
        let readyURL = rootURL.appendingPathComponent("holder-ready")
        let lockURL = rootURL.appendingPathComponent("bridge-v5.lock")
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

    private func makeBridge(
        clock: @escaping () -> Date = Date.init,
        atomicWrite: @escaping ExtensionRequestFileStore.AtomicWrite =
            ExtensionRequestFileStore.defaultAtomicWrite
    ) -> ExtensionBridge {
        ExtensionBridge(store: ExtensionRequestFileStore(
            rootURL: rootURL,
            dependencies: .init(clock: clock, atomicWrite: atomicWrite)
        ))
    }

    private func makeFixture(
        id: Int,
        host: String = "wallet.example",
        configurationKey: String? = nil,
        enqueueAttempt: String? = nil,
        admissionDeadline: Date? = nil,
        message: String = "0x48656c6c6f",
        favicon: String = "",
        revisions: [String: Int] = ["ethereum": 0, "solana": 0]
    ) throws -> Fixture {
        let configurationKey = configurationKey ?? "https://\(host)"
        let object: [String: Any] = [
            "id": id,
            "name": "signPersonalMessage",
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
            "revisions": revisions,
            "body": [
                "address": "0x0000000000000000000000000000000000000042",
                "object": ["data": message],
            ],
        ]
        let request = try XCTUnwrap(SafariRequest(json: object))
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(
            request: request,
            rawObject: object
        ) else { throw Failure.expectedValue }
        return Fixture(request: request, ingress: ingress)
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
        revisions: ExtensionBridge.ProviderRevisions
    ) {
        guard case .accepted(
            let handle,
            let approvalRequired,
            let revisions
        ) = result else {
            XCTFail("Expected accepted enqueue", file: file, line: line)
            throw Failure.expectedValue
        }
        return (handle, approvalRequired, revisions)
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

    private func response(for request: SafariRequest) -> ResponseToExtension {
        ResponseToExtension(
            for: request,
            payload: .body(.ethereum(.init(result: "0xsigned")))
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
                message: "oversized",
                code: ProviderResponseError.internalErrorCode,
                context: .dataJSON(String(
                    repeating: "x",
                    count: ExtensionBridge.maximumPayloadBytes
                ))
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
        return response
    }

    private var defaultProfileURL: URL {
        profileURL(nil)
    }

    private func profileURL(_ profileIdentifier: UUID?) -> URL {
        let name = profileIdentifier?.uuidString.lowercased() ?? "default"
        return rootURL
            .appendingPathComponent("profiles-v5", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("state")
    }

    private func operationLockURL(_ handle: ExtensionBridge.Handle) -> URL {
        let profile = handle.profileIdentifier?.uuidString.lowercased() ?? "default"
        return rootURL
            .appendingPathComponent("operation-locks-v5", isDirectory: true)
            .appendingPathComponent("\(profile)-\(handle.token.rawValue)")
            .appendingPathExtension("lock")
    }

    private func firstStoredCreatedAt() throws -> Date {
        let profile = try storedProfile()
        let records = try XCTUnwrap(profile["records"] as? [[String: Any]])
        return try XCTUnwrap(records.first?["createdAt"] as? Date)
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

    private func storedProfile() throws -> [String: Any] {
        let data = try Data(contentsOf: defaultProfileURL)
        return try XCTUnwrap(PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any])
    }
}
