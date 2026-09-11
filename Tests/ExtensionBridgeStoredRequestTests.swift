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
            "extension-bridge-v6-\(UUID().uuidString)",
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
        XCTAssertEqual(ExtensionBridge.nativeExecutionTimeout, 160)

        let fixture = try makeFixture(id: 1)
        guard case .rejected = await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil,
            privateBrowsing: true
        ) else { return XCTFail("Expected private browsing rejection") }
    }

    #if os(macOS)
    func testEmbeddedHelperStaysInsideTheSafariExtensionBundle() throws {
        let extensionURL = URL(fileURLWithPath:
            "/Users/developer/Build/Wallet.app/Contents/PlugIns/Safari macOS.appex",
            isDirectory: true
        )
        let helperURL = try XCTUnwrap(
            NativeAgentLauncher.embeddedHelperURL(in: extensionURL)
        )
        XCTAssertEqual(
            helperURL.path,
            extensionURL.path + "/Contents/Helpers/Big Wallet.app"
        )
        XCTAssertNil(NativeAgentLauncher.embeddedHelperURL(
            in: extensionURL.deletingLastPathComponent()
        ))
        XCTAssertNil(NativeAgentLauncher.embeddedHelperURL(
            in: URL(string: "https://example.com/Safari.appex")!
        ))
    }
    #endif

    func testStoreUsesV6AndIgnoresUnreleasedV5Profiles() async throws {
        let oldDirectory = rootURL.appendingPathComponent(
            "profiles-v5",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: oldDirectory,
            withIntermediateDirectories: true
        )
        let oldProfileURL = oldDirectory.appendingPathComponent("default.state")
        let oldProfile = try PropertyListSerialization.data(
            fromPropertyList: [
                "schemaVersion": 5,
                "workflowVersion": ExtensionBridge.workflowVersion,
                "records": [],
            ],
            format: .binary,
            options: 0
        )
        try oldProfile.write(to: oldProfileURL, options: .atomic)

        guard case .available(let initial) = await bridge.list(
            profileIdentifier: nil
        ) else { return XCTFail("Expected V6 store") }
        XCTAssertTrue(initial.isEmpty)

        _ = try accepted(await bridge.enqueue(
            ingress: try makeFixture(id: 81).ingress,
            profileIdentifier: nil
        ))
        let profile = try storedProfile()
        XCTAssertEqual(profile["schemaVersion"] as? Int, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldProfileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultProfileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL
            .appendingPathComponent("operation-locks-v6", isDirectory: true)
            .path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL
            .appendingPathComponent(
                "native-execution-fences-v6",
                isDirectory: true
            ).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL
            .appendingPathComponent("operation-locks-v5", isDirectory: true)
            .path))
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

    func testNativeDeliveryReceiptIsIdempotentOwnedAndClearedAtCompletion() async throws {
        let fixture = try makeFixture(id: 82)
        let admission = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let firstRuntime = UUID()
        let secondRuntime = UUID()
        let owner = try XCTUnwrap(ExtensionBridge.NativeDeliveryOwner(
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
            runtimeInstanceIdentifier: firstRuntime,
            owner: owner
        )
        XCTAssertEqual(firstRecord, .persisted)
        let duplicateRecord = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime,
            owner: owner
        )
        XCTAssertEqual(duplicateRecord, .persisted)
        let conflictingRecord = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: secondRuntime
        )
        XCTAssertEqual(conflictingRecord, .ownershipLost)
        guard case .found(let owned) = await bridge.load(
            handle: admission.handle
        ) else { return XCTFail("Expected owned delivery") }
        XCTAssertEqual(
            owned.nativeDeliveryReceipt,
            .init(
                nativeDeliveryNonce: admission.nativeDeliveryNonce,
                runtimeInstanceIdentifier: firstRuntime,
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
            runtimeInstanceIdentifier: secondRuntime,
            owner: owner
        )
        XCTAssertEqual(secondRecord, .persisted)
        let staged = await bridge.stageNativeDecision(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: secondRuntime,
            decision: .message(.init(solanaCluster: nil))
        )
        XCTAssertEqual(staged, .persisted)
        let execution = try await makeNativeDecisionExecutable(
            handle: admission.handle,
            configurationKey: fixture.request.configurationKey,
            revisions: admission.revisions
        )
        defer { execution.fence.release() }
        let claim: ExtensionBridge.NativeDecisionClaim
        guard case .claimed(let value) = await bridge
                .claimExecutableNativeDecision(
            handle: admission.handle
        ) else { return XCTFail("Expected native claim") }
        claim = value
        let permit = try executionPermit(await bridge.begin(
            claim: claim.approvalClaim
        ))
        let completion = await bridge.complete(
            permit: permit,
            response: response(for: fixture.request),
            authority: .native(execution.context)
        )
        XCTAssertEqual(completion, .persisted)
        guard case .found(let completed) = await bridge.load(
            handle: admission.handle
        ) else { return XCTFail("Expected completed delivery") }
        XCTAssertEqual(completed.phase, .responded)
        XCTAssertNil(completed.nativeDeliveryReceipt)
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
            runtimeInstanceIdentifier: UUID()
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
                try ExtensionRequestFileStore.defaultAtomicWrite(data, url)
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
            runtimeInstanceIdentifier: runtime
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

        let stageFixture = try makeFixture(id: 85)
        let stageAdmission = try accepted(await bridge.enqueue(
            ingress: stageFixture.ingress,
            profileIdentifier: nil
        ))
        let recordedStage = await bridge.recordNativeDeliveryReceipt(
            handle: stageAdmission.handle,
            nativeDeliveryNonce: stageAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime
        )
        XCTAssertEqual(recordedStage, .persisted)
        let ownerlessStage = await bridge.stageNativeDecision(
            handle: stageAdmission.handle,
            decision: .message(.init(solanaCluster: nil))
        )
        XCTAssertEqual(ownerlessStage, .ownershipLost)
        let wrongNonceStage = await bridge.stageNativeDecision(
            handle: stageAdmission.handle,
            nativeDeliveryNonce: wrongNonce,
            runtimeInstanceIdentifier: firstRuntime,
            decision: .message(.init(solanaCluster: nil))
        )
        XCTAssertEqual(wrongNonceStage, .ownershipLost)
        let wrongOwnerStage = await bridge.stageNativeDecision(
            handle: stageAdmission.handle,
            nativeDeliveryNonce: stageAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: wrongRuntime,
            decision: .message(.init(solanaCluster: nil))
        )
        XCTAssertEqual(wrongOwnerStage, .ownershipLost)
        let staged = await bridge.stageNativeDecision(
            handle: stageAdmission.handle,
            nativeDeliveryNonce: stageAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime,
            decision: .message(.init(solanaCluster: nil))
        )
        XCTAssertEqual(staged, .persisted)
        guard case .found(let stagedSnapshot) = await bridge.load(
            handle: stageAdmission.handle
        ) else { return XCTFail("Expected staged delivery") }
        XCTAssertTrue(stagedSnapshot.nativeDecisionStaged)
        XCTAssertEqual(
            stagedSnapshot.nativeDeliveryReceipt?.runtimeInstanceIdentifier,
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
            runtimeInstanceIdentifier: firstRuntime
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
            runtimeInstanceIdentifier: firstRuntime
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
                try ExtensionRequestFileStore.defaultAtomicWrite(data, url)
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

        let stageFixture = try makeFixture(id: 88)
        let stageAdmission = try accepted(await bridge.enqueue(
            ingress: stageFixture.ingress,
            profileIdentifier: nil
        ))
        let stageReceipt = await bridge.recordNativeDeliveryReceipt(
            handle: stageAdmission.handle,
            nativeDeliveryNonce: stageAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime
        )
        XCTAssertEqual(stageReceipt, .persisted)
        writes.throwsRemaining = 1
        let staged = await bridge.stageNativeDecision(
            handle: stageAdmission.handle,
            nativeDeliveryNonce: stageAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime,
            decision: .message(.init(solanaCluster: nil))
        )
        XCTAssertEqual(staged, .persisted)

        let completeFixture = try makeFixture(id: 89)
        let completeAdmission = try accepted(await bridge.enqueue(
            ingress: completeFixture.ingress,
            profileIdentifier: nil
        ))
        let completeReceipt = await bridge.recordNativeDeliveryReceipt(
            handle: completeAdmission.handle,
            nativeDeliveryNonce: completeAdmission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime
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
            runtimeInstanceIdentifier: firstRuntime
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

    func testManualSwitchReplayKeepsOriginalBodyAcrossConfigurationDrift() async throws {
        let attempt = String(repeating: "e", count: 32)
        let original = try makeManualFixture(
            id: 405,
            enqueueAttempt: attempt,
            latestConfigurations: [[
                "provider": "ethereum",
                "chainId": "0x1",
                "results": ["0x0000000000000000000000000000000000000001"],
            ]],
            revisions: ["ethereum": 0, "solana": 0]
        )
        let drifted = try makeManualFixture(
            id: 405,
            enqueueAttempt: attempt,
            latestConfigurations: [],
            revisions: ["ethereum": 1, "solana": 0]
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
        let recovered = try responseJSON(await observer.readResponse(
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
        let profile = try storedProfile()
        let records = try XCTUnwrap(profile["records"] as? [[String: Any]])
        XCTAssertNil(records[0]["responseAcknowledged"])
        guard case .available(let initial) = await bridge.list(profileIdentifier: nil)
        else { return XCTFail("Expected legacy-compatible unacknowledged listing") }
        XCTAssertNotNil(initial[handle])

        clock.now.addTimeInterval(60)
        let acknowledged = await bridge.acknowledgeResponse(
            handle: handle,
            configurationKey: fixture.request.configurationKey
        )
        XCTAssertEqual(acknowledged, .persisted)
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
        let recovered = try responseJSON(await observer.readResponse(
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
                try ExtensionRequestFileStore.defaultAtomicWrite(data, url)
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
        let protectedResponse = try responseJSON(await bridge.readResponse(
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

    func testAdmissionReservesSpaceForBroadcastAndCompletion() async throws {
        let fixture = try makeFixture(
            id: 1000,
            host: "signing.example",
            message: "0x" + String(repeating: "ab", count: 120 * 1024)
        )
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let claim = try approvalClaim(await bridge.claim(handle: handle))
        let permit = try executionPermit(await bridge.begin(claim: claim))
        _ = try await fillCompletedByteCapacity()
        let prepared = await bridge.prepareBroadcast(
            permit: permit,
            recoveryResponse: largeResponse(for: fixture.request),
            authority: .ordinary
        )
        XCTAssertEqual(prepared, .persisted)
        let completion = await bridge.complete(
            permit: permit,
            response: largeResponse(for: fixture.request),
            authority: .ordinary
        )
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
            let deadline = clock.now.addingTimeInterval(1)
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
            recoveryResponse: recovery,
            authority: .ordinary
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
            recoveryResponse: recovery,
            authority: .ordinary
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
            recoveryResponse: recovery,
            authority: .ordinary
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

        let completion = await bridge.complete(
            permit: permit,
            response: oversized,
            authority: .ordinary
        )
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

    func testNativeDecisionStagingIsProfileScopedAndInvisibleToPopupClaims() async throws {
        let profile = UUID()
        let fixture = try makeFixture(id: 720)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: profile
        )).handle
        let decision = NativeApprovalDecision.message(.init(solanaCluster: nil))

        let staged = await bridge.stageNativeDecision(
            handle: handle,
            decision: decision
        )
        XCTAssertEqual(staged, .persisted)
        let originalStagedAt = clock.now
        clock.now = clock.now.addingTimeInterval(10)
        let duplicate = await bridge.stageNativeDecision(
            handle: handle,
            decision: decision
        )
        XCTAssertEqual(duplicate, .persisted)
        let conflicting = await bridge.stageNativeDecision(
            handle: handle,
            decision: .addEthereumChain
        )
        XCTAssertEqual(conflicting, .ownershipLost)
        guard case .found(let snapshot) = await bridge.load(handle: handle) else {
            return XCTFail("Expected staged snapshot")
        }
        XCTAssertTrue(snapshot.nativeDecisionStaged)
        guard case .executing = await bridge.claim(handle: handle) else {
            return XCTFail("Popup claim must not consume native decision")
        }
        let execution = try await makeNativeDecisionExecutable(
            handle: handle,
            configurationKey: fixture.request.configurationKey,
            revisions: snapshot.revisions
        )
        defer { execution.fence.release() }
        let wrongProfileHandle = ExtensionBridge.Handle(
            id: handle.id,
            token: handle.token,
            profileIdentifier: nil
        )
        guard case .missing = await bridge.claimExecutableNativeDecision(
            handle: wrongProfileHandle
        ) else { return XCTFail("Expected profile isolation") }

        guard case .claimed(let nativeClaim) = await bridge
                .claimExecutableNativeDecision(handle: handle) else {
            return XCTFail("Expected native claim")
        }
        XCTAssertEqual(nativeClaim.decision, decision)
        XCTAssertEqual(nativeClaim.stagedAt, originalStagedAt)
        let releasedClaim = await bridge.release(
            claim: nativeClaim.approvalClaim
        )
        XCTAssertEqual(releasedClaim, .persisted)
        guard case .found(let released) = await bridge.load(handle: handle) else {
            return XCTFail("Expected released snapshot")
        }
        XCTAssertEqual(released.phase, .queued)
        XCTAssertTrue(released.nativeDecisionStaged)
        guard case .claimed(let reclaimed) = await bridge
                .claimExecutableNativeDecision(handle: handle) else {
            return XCTFail("Expected reclaimed native decision")
        }
        XCTAssertEqual(reclaimed.stagedAt, originalStagedAt)
        let rereleased = await bridge.release(claim: reclaimed.approvalClaim)
        XCTAssertEqual(rereleased, .persisted)
        let rejected = await bridge.reject(handle: handle)
        XCTAssertEqual(rejected, .ownershipLost)
    }

    func testNativeExecutionContextRefreshesAndRequiresMatchingLiveFence()
        async throws {
        let fixture = try makeFixture(id: 726)
        let admission = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let runtime = UUID()
        let executionDeadline = clock.now.addingTimeInterval(120)
        let receiptResult = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtime
        )
        XCTAssertEqual(receiptResult, .persisted)
        let prematureContext = await bridge.recordNativeExecutionContext(
            handle: admission.handle,
            configurationKey: fixture.request.configurationKey,
            revisions: try XCTUnwrap(.init(rawValue: [
                "ethereum": 3,
                "solana": 5,
            ])),
            executionDeadline: executionDeadline,
            fenceToken: UUID()
        )
        XCTAssertEqual(prematureContext, .pending)
        let stageResult = await bridge.stageNativeDecision(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtime,
            decision: .message(.init(solanaCluster: nil))
        )
        XCTAssertEqual(stageResult, .persisted)
        let prematureClaim = await bridge.claimExecutableNativeDecision(
            handle: admission.handle
        )
        guard case .notStaged = prematureClaim else {
            return XCTFail(
                "Execution must wait for page revisions: \(prematureClaim)"
            )
        }
        let firstFenceToken = UUID()
        let firstAcquiredFence = await bridge.acquireNativeExecutionFence(
            handle: admission.handle,
            token: firstFenceToken
        )
        let firstFence = try XCTUnwrap(firstAcquiredFence)
        let firstFenceHeld = await bridge.nativeExecutionFenceIsHeld(
            handle: admission.handle,
            token: firstFenceToken
        )
        let wrongFenceHeld = await bridge.nativeExecutionFenceIsHeld(
            handle: admission.handle,
            token: UUID()
        )
        XCTAssertTrue(firstFenceHeld)
        XCTAssertFalse(wrongFenceHeld)

        let first = try XCTUnwrap(ExtensionBridge.ProviderRevisions(
            rawValue: ["ethereum": 7, "solana": 11]
        ))
        let firstContextResult = await bridge.recordNativeExecutionContext(
            handle: admission.handle,
            configurationKey: fixture.request.configurationKey,
            revisions: first,
            executionDeadline: executionDeadline,
            fenceToken: firstFenceToken
        )
        guard case .recorded(let firstContext) = firstContextResult else {
            return XCTFail("Expected execution context")
        }
        XCTAssertEqual(firstContext.revisions, first)
        clock.now = clock.now.addingTimeInterval(1)
        let refreshed = try XCTUnwrap(ExtensionBridge.ProviderRevisions(
            rawValue: ["ethereum": 8, "solana": 12]
        ))
        let refreshedContextResult = await bridge.recordNativeExecutionContext(
            handle: admission.handle,
            configurationKey: fixture.request.configurationKey,
            revisions: refreshed,
            executionDeadline: executionDeadline,
            fenceToken: firstFenceToken
        )
        guard case .recorded(let refreshedContext) = refreshedContextResult else {
            return XCTFail("Expected refreshed execution context")
        }
        XCTAssertEqual(refreshedContext.revisions, refreshed)
        XCTAssertGreaterThan(
            refreshedContext.observedAt,
            firstContext.observedAt
        )
        guard case .found(let staged) = await bridge.load(
            handle: admission.handle
        ) else { return XCTFail("Expected staged request") }
        XCTAssertEqual(staged.nativeExecutionContext, refreshedContext)
        firstFence.release()
        let releasedFenceHeld = await bridge.nativeExecutionFenceIsHeld(
            handle: admission.handle,
            token: firstFenceToken
        )
        XCTAssertFalse(releasedFenceHeld)
        guard case .notStaged = await bridge.claimExecutableNativeDecision(
            handle: admission.handle
        ) else { return XCTFail("Execution must require a live Safari fence") }
        let executionFenceToken = UUID()
        let acquiredFence = await bridge.acquireNativeExecutionFence(
            handle: admission.handle,
            token: executionFenceToken
        )
        let executionFence = try XCTUnwrap(acquiredFence)
        defer { executionFence.release() }
        guard case .notStaged = await bridge.claimExecutableNativeDecision(
            handle: admission.handle
        ) else { return XCTFail("A replacement fence cannot authorize old context") }
        let executableContextResult = await bridge.recordNativeExecutionContext(
            handle: admission.handle,
            configurationKey: fixture.request.configurationKey,
            revisions: refreshed,
            executionDeadline: executionDeadline,
            fenceToken: executionFenceToken
        )
        guard case .recorded(let executableContext) = executableContextResult else {
            return XCTFail("Expected fence-bound execution context")
        }

        let clearResult = await bridge.clearNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtime
        )
        XCTAssertEqual(clearResult, .persisted)
        let replacementRuntime = UUID()
        let replacementResult = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: replacementRuntime
        )
        XCTAssertEqual(replacementResult, .persisted)
        guard case .claimed(let claim) =
                await bridge.claimExecutableNativeDecision(
                    handle: admission.handle
                ) else { return XCTFail("Expected executable native claim") }
        XCTAssertEqual(claim.executionContext, executableContext)
        let releaseResult = await bridge.release(claim: claim.approvalClaim)
        XCTAssertEqual(releaseResult, .persisted)
        guard case .found(let released) = await bridge.load(
            handle: admission.handle
        ) else { return XCTFail("Expected released request") }
        XCTAssertEqual(released.nativeExecutionContext, executableContext)
        let clearedContext = await bridge.clearNativeExecutionContext(
            handle: admission.handle,
            expected: executableContext
        )
        XCTAssertEqual(clearedContext, .persisted)
        guard case .found(let cleared) = await bridge.load(
            handle: admission.handle
        ) else { return XCTFail("Expected retained staged request") }
        XCTAssertNil(cleared.nativeExecutionContext)
    }

    func testReplacedNativeFenceCannotCompleteClaimedExecution()
        async throws {
        let execution = try await makeExecutableNativePermit(id: 727)
        let initiallyHeld = await bridge.nativeExecutionFenceIsHeld(
            handle: execution.handle,
            token: execution.context.fenceToken
        )
        XCTAssertTrue(initiallyHeld)
        execution.fence.release()
        let acquiredReplacement = await bridge.acquireNativeExecutionFence(
            handle: execution.handle,
            token: UUID()
        )
        let replacement = try XCTUnwrap(acquiredReplacement)
        defer { replacement.release() }

        let unboundCompletion = await bridge.complete(
            permit: execution.permit,
            response: response(for: execution.request),
            authority: .ordinary
        )
        XCTAssertEqual(unboundCompletion, .ownershipLost)
        let completion = await bridge.complete(
            permit: execution.permit,
            response: response(for: execution.request),
            authority: .native(execution.context)
        )
        XCTAssertEqual(completion, .ownershipLost)
        let rollback = await bridge.rollback(permit: execution.permit)
        XCTAssertEqual(rollback, .persisted)
        guard case .found(let snapshot) = await bridge.load(
            handle: execution.handle
        ) else { return XCTFail("Expected rolled-back request") }
        XCTAssertEqual(snapshot.phase, .queued)
    }

    func testReplacedNativeFenceCannotCheckpointBroadcast()
        async throws {
        let execution = try await makeExecutableNativePermit(id: 728)
        let initiallyHeld = await bridge.nativeExecutionFenceIsHeld(
            handle: execution.handle,
            token: execution.context.fenceToken
        )
        XCTAssertTrue(initiallyHeld)
        execution.fence.release()
        let acquiredReplacement = await bridge.acquireNativeExecutionFence(
            handle: execution.handle,
            token: UUID()
        )
        let replacement = try XCTUnwrap(acquiredReplacement)
        defer { replacement.release() }

        let unboundCheckpoint = await bridge.prepareBroadcast(
            permit: execution.permit,
            recoveryResponse: response(for: execution.request),
            authority: .ordinary
        )
        XCTAssertEqual(unboundCheckpoint, .ownershipLost)
        let checkpoint = await bridge.prepareBroadcast(
            permit: execution.permit,
            recoveryResponse: response(for: execution.request),
            authority: .native(execution.context)
        )
        XCTAssertEqual(checkpoint, .ownershipLost)
        let rollback = await bridge.rollback(permit: execution.permit)
        XCTAssertEqual(rollback, .persisted)
        guard case .found(let snapshot) = await bridge.load(
            handle: execution.handle
        ) else { return XCTFail("Expected rolled-back request") }
        XCTAssertEqual(snapshot.phase, .queued)
    }

    func testBroadcastCheckpointTransfersNativeFenceAuthority()
        async throws {
        let execution = try await makeExecutableNativePermit(id: 729)
        let checkpoint = await bridge.prepareBroadcast(
            permit: execution.permit,
            recoveryResponse: response(for: execution.request),
            authority: .native(execution.context)
        )
        XCTAssertEqual(checkpoint, .persisted)
        guard case .found(let prepared) = await bridge.load(
            handle: execution.handle
        ) else { return XCTFail("Expected prepared broadcast") }
        XCTAssertNil(prepared.nativeExecutionContext)

        execution.fence.release()
        let completion = await bridge.complete(
            permit: execution.permit,
            response: response(for: execution.request),
            authority: .ordinary
        )
        XCTAssertEqual(completion, .persisted)
        guard case .found(let completed) = await bridge.load(
            handle: execution.handle
        ) else { return XCTFail("Expected completed request") }
        XCTAssertEqual(completed.phase, .responded)
    }

    func testFutureNativeDecisionTimestampCannotBecomeExecutable() async throws {
        let fixture = try makeFixture(id: 725)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let staged = await bridge.stageNativeDecision(
            handle: handle,
            decision: .message(.init(solanaCluster: nil))
        )
        XCTAssertEqual(staged, .persisted)
        let future = clock.now.addingTimeInterval(60 * 60)
        try mutateFirstStoredRecord { record in
            record["nativeDecisionStagedAt"] = future
        }
        let fenceToken = UUID()
        let acquiredFence = await bridge.acquireNativeExecutionFence(
            handle: handle,
            token: fenceToken
        )
        let fence = try XCTUnwrap(acquiredFence)
        defer { fence.release() }
        let context = await bridge.recordNativeExecutionContext(
            handle: handle,
            configurationKey: fixture.request.configurationKey,
            revisions: try XCTUnwrap(.init(rawValue: [
                "ethereum": 0,
                "solana": 0,
            ])),
            executionDeadline: clock.now.addingTimeInterval(120),
            fenceToken: fenceToken
        )
        XCTAssertEqual(context, .unavailable)
        let claim = await bridge.claimExecutableNativeDecision(handle: handle)
        XCTAssertEqual(claim, .notStaged)
    }

    func testNativeDecisionSurvivesClaimRecoveryAndClearsAfterBroadcastRecovery() async throws {
        let fixture = try makeFixture(id: 721)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let decision = NativeApprovalDecision.message(.init(solanaCluster: nil))
        let staged = await bridge.stageNativeDecision(
            handle: handle,
            decision: decision
        )
        XCTAssertEqual(staged, .persisted)
        let execution = try await makeNativeDecisionExecutable(
            handle: handle,
            configurationKey: fixture.request.configurationKey,
            revisions: try XCTUnwrap(.init(rawValue: [
                "ethereum": 0,
                "solana": 0,
            ]))
        )
        defer { execution.fence.release() }

        var nativeClaim: ExtensionBridge.NativeDecisionClaim?
        switch await bridge.claimExecutableNativeDecision(handle: handle) {
        case .claimed(let value):
            nativeClaim = value
        case .notStaged, .executing, .responded, .missing, .unavailable:
            return XCTFail("Expected native claim")
        }
        XCTAssertNotNil(nativeClaim)
        nativeClaim = nil
        let observer = makeBridge(clock: { self.clock.now })
        guard case .found(let recovered) = await observer.load(handle: handle) else {
            return XCTFail("Expected recovered claim")
        }
        XCTAssertEqual(recovered.phase, .queued)
        XCTAssertTrue(recovered.nativeDecisionStaged)

        var reclaimed: ExtensionBridge.NativeDecisionClaim?
        switch await observer.claimExecutableNativeDecision(handle: handle) {
        case .claimed(let value):
            reclaimed = value
        case .notStaged, .executing, .responded, .missing, .unavailable:
            return XCTFail("Expected reclaimed native decision")
        }
        var permit: ExtensionBridge.ExecutionPermit? = try executionPermit(
            await observer.begin(claim: try XCTUnwrap(reclaimed).approvalClaim)
        )
        reclaimed = nil
        let recovery = response(for: fixture.request).markingApprovalCommitted()
        let prepared = await observer.prepareBroadcast(
            permit: try XCTUnwrap(permit),
            recoveryResponse: recovery,
            authority: .native(execution.context)
        )
        XCTAssertEqual(prepared, .persisted)
        permit = nil
        let recoveryObserver = makeBridge(clock: { self.clock.now })
        guard case .found(let completed) = await recoveryObserver.load(
            handle: handle
        ) else { return XCTFail("Expected broadcast recovery") }
        XCTAssertEqual(completed.phase, .responded)
        XCTAssertFalse(completed.nativeDecisionStaged)
        let delivered = try responseJSON(await recoveryObserver.readResponse(
            id: handle.id,
            configurationKey: fixture.request.configurationKey,
            requestToken: handle.requestToken,
            profileIdentifier: nil
        ))
        XCTAssertEqual(
            delivered[ExtensionBridge.approvalCommittedKey] as? Bool,
            true
        )
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

    func testNativeTransactionDecisionRebuildsOnlyMutableExecutionFields() throws {
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
        let execution = try XCTUnwrap(
            NativeApprovalDecision.TransactionExecution(
                edited,
                reviewedNetwork: resolvedNetwork
            )
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
            account: account,
            resolve: { _ -> DappExecutionResult in fatalError() }
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
            account: account,
            resolve: { _ -> DappExecutionResult in fatalError() }
        )
        XCTAssertNil(execution.applying(to: changedAction))

        let encoded = try XCTUnwrap(
            NativeApprovalDecision.transaction(execution).boundedData
        )
        XCTAssertEqual(
            NativeApprovalDecision.decodeBounded(encoded),
            .transaction(execution)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["kind"] as? String, "transactionV2")
        XCTAssertFalse(Set([
            "accountSelection", "message", "transaction", "addEthereumChain",
        ]).contains(object["kind"] as? String ?? ""))
        var transactionObject = try XCTUnwrap(
            object["transaction"] as? [String: Any]
        )
        transactionObject.removeValue(forKey: "reviewedNetwork")
        object["kind"] = "transaction"
        object["transaction"] = transactionObject
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        guard case .transaction(let legacyExecution) =
                NativeApprovalDecision.decodeBounded(legacyData) else {
            return XCTFail("Expected compatible legacy decision decoding")
        }
        XCTAssertNil(legacyExecution.applying(to: action))
    }

    #if os(macOS)
    func testRuntimeIdentityLoadsOlderProtocolForCompatibilityChecks() throws {
        let bundleURL = try makeAmbientBundle(name: "Protocol", build: "148")
        let identity = try runtimeIdentity(
            processIdentifier: 791,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 1_789_118_464.514548),
            runtimeProtocolVersion: 2
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")

        XCTAssertTrue(identity.persist(directoryURL: directoryURL))
        XCTAssertEqual(
            AmbientRuntimeIdentity.load(
                processIdentifier: identity.processIdentifier,
                directoryURL: directoryURL,
                legacyData: { _ in
                    XCTFail("An existing identity file must not read defaults")
                    return nil
                }
            ),
            identity
        )
        XCTAssertFalse(identity.isCompatible(
            withWorkflowVersion: ExtensionBridge.workflowVersion
        ))
    }

    func testRuntimeIdentityPersistenceReportsWriteFailure() throws {
        let bundleURL = try makeAmbientBundle(name: "Persist", build: "148")
        let identity = try runtimeIdentity(
            processIdentifier: 792,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_001)
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")

        XCTAssertFalse(identity.persist(
            directoryURL: directoryURL,
            atomicWrite: { _, _ in throw Failure.injectedWrite }
        ))
        XCTAssertFalse(identity.persist(
            directoryURL: directoryURL,
            atomicWrite: { _, _ in }
        ))
        XCTAssertNil(AmbientRuntimeIdentity.load(
            processIdentifier: identity.processIdentifier,
            directoryURL: directoryURL,
            legacyData: { _ in nil }
        ))
        XCTAssertTrue(identity.persist(directoryURL: directoryURL))
        XCTAssertEqual(AmbientRuntimeIdentity.load(
            processIdentifier: identity.processIdentifier,
            directoryURL: directoryURL
        ), identity)
    }

    func testRuntimeIdentityClearReportsRemovalFailureAndRetries() throws {
        let bundleURL = try makeAmbientBundle(name: "Clear", build: "148")
        let identity = try runtimeIdentity(
            processIdentifier: 793,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_002)
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")
        XCTAssertTrue(identity.persist(directoryURL: directoryURL))

        XCTAssertFalse(identity.clear(
            directoryURL: directoryURL,
            removeItem: { _ in throw Failure.injectedWrite }
        ))
        XCTAssertFalse(identity.clear(
            directoryURL: directoryURL,
            removeItem: { _ in }
        ))
        XCTAssertEqual(AmbientRuntimeIdentity.load(
            processIdentifier: identity.processIdentifier,
            directoryURL: directoryURL
        ), identity)

        XCTAssertTrue(identity.clear(directoryURL: directoryURL))
        XCTAssertTrue(identity.clear(directoryURL: directoryURL))
        XCTAssertNil(AmbientRuntimeIdentity.load(
            processIdentifier: identity.processIdentifier,
            directoryURL: directoryURL,
            legacyData: { _ in nil }
        ))
    }

    func testRuntimeIdentityClearPreservesReplacementInstance() throws {
        let bundleURL = try makeAmbientBundle(name: "Replaced", build: "148")
        let original = try runtimeIdentity(
            processIdentifier: 794,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_003)
        )
        let replacement = try runtimeIdentity(
            processIdentifier: original.processIdentifier,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_004)
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")
        XCTAssertTrue(original.persist(directoryURL: directoryURL))
        XCTAssertEqual(AmbientRuntimeIdentity.load(
            processIdentifier: original.processIdentifier,
            directoryURL: directoryURL
        ), original)
        XCTAssertTrue(replacement.persist(directoryURL: directoryURL))

        XCTAssertFalse(original.clear(directoryURL: directoryURL))
        XCTAssertEqual(AmbientRuntimeIdentity.load(
            processIdentifier: original.processIdentifier,
            directoryURL: directoryURL
        ), replacement)
        XCTAssertTrue(replacement.clear(directoryURL: directoryURL))
    }

    func testRuntimeIdentityRejectsMalformedAndMismatchedFiles() throws {
        let bundleURL = try makeAmbientBundle(name: "Invalid", build: "148")
        let identity = try runtimeIdentity(
            processIdentifier: 795,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_005)
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")
        XCTAssertTrue(identity.persist(directoryURL: directoryURL))
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
                directoryURL: directoryURL,
                legacyData: { _ in
                    XCTFail("An invalid file must not fall back to defaults")
                    return data
                }
            ))
        }
        XCTAssertNil(AmbientRuntimeIdentity.load(
            processIdentifier: 0,
            directoryURL: directoryURL,
            legacyData: { _ in
                XCTFail("Invalid PIDs must not read defaults")
                return data
            }
        ))
    }

    func testRuntimeIdentityDoesNotFallBackForUnreadableOrUnsafeFiles() throws {
        let bundleURL = try makeAmbientBundle(name: "Unreadable", build: "148")
        let identity = try runtimeIdentity(
            processIdentifier: 796,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_006)
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")
        XCTAssertTrue(identity.persist(directoryURL: directoryURL))
        let fileURL = directoryURL.appendingPathComponent("796.json")
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
            directoryURL: directoryURL,
            legacyData: { _ in
                XCTFail("An unreadable file must not read defaults")
                return nil
            }
        ))
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createSymbolicLink(
            at: fileURL,
            withDestinationURL: directoryURL.appendingPathComponent("missing")
        )
        XCTAssertNil(AmbientRuntimeIdentity.load(
            processIdentifier: identity.processIdentifier,
            directoryURL: directoryURL,
            legacyData: { _ in
                XCTFail("An unsafe file must not read defaults")
                return nil
            }
        ))
    }

    func testRuntimeIdentityReadsLegacyDefaultsOnlyForOlderMissingFiles() throws {
        let bundleURL = try makeAmbientBundle(name: "Legacy", build: "148")
        let identity = try runtimeIdentity(
            processIdentifier: 797,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_007),
            runtimeProtocolVersion: 3
        )
        let directoryURL = rootURL.appendingPathComponent("runtime-identities")
        let legacyData = try JSONEncoder().encode(identity)
        XCTAssertEqual(AmbientRuntimeIdentity.currentRuntimeProtocolVersion, 4)
        XCTAssertEqual(AmbientRuntimeIdentity.load(
            processIdentifier: identity.processIdentifier,
            directoryURL: directoryURL,
            legacyData: { pid in
                XCTAssertEqual(pid, identity.processIdentifier)
                return legacyData
            }
        ), identity)
        XCTAssertFalse(identity.isCompatible(
            withWorkflowVersion: ExtensionBridge.workflowVersion
        ))

        let current = try runtimeIdentity(
            processIdentifier: identity.processIdentifier,
            bundleURL: bundleURL,
            launchDate: Date(timeIntervalSince1970: 9_008)
        )
        let currentData = try JSONEncoder().encode(current)
        XCTAssertNil(AmbientRuntimeIdentity.load(
            processIdentifier: current.processIdentifier,
            directoryURL: directoryURL,
            legacyData: { _ in currentData }
        ))
        XCTAssertNil(AmbientRuntimeIdentity.load(
            processIdentifier: current.processIdentifier + 1,
            directoryURL: directoryURL,
            legacyData: { _ in legacyData }
        ))
        XCTAssertNil(AmbientRuntimeIdentity.load(
            processIdentifier: current.processIdentifier,
            directoryURL: directoryURL,
            legacyData: { _ in Data(repeating: 0x20, count: 4_097) }
        ))
        XCTAssertTrue(current.persist(directoryURL: directoryURL))
        XCTAssertEqual(AmbientRuntimeIdentity.load(
            processIdentifier: current.processIdentifier,
            directoryURL: directoryURL,
            legacyData: { _ in
                XCTFail("Current runtime identity must come from its file")
                return legacyData
            }
        ), current)
    }

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
        let selected = await NativeAgentLauncher.resolveTargetHelper(
            currentURL: currentURL,
            deadline: UInt64.max,
            isPending: { true },
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
            identity: { identities[$0] },
            validate: { $0 == currentURL }
        )

        guard let selected, case .running(
                  let selectedURL,
                  let processIdentifier,
                  let runtimeInstanceIdentifier
              ) = selected else { return XCTFail("Expected running target") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertEqual(processIdentifier, 801)
        XCTAssertEqual(
            runtimeInstanceIdentifier,
            identities[801]?.instanceIdentifier
        )
    }

    func testNativeAgentResolutionFailsClosedWhenUnknownRetirementIsRefused()
        async throws {
        let currentURL = try makeAmbientBundle(name: "Unknown", build: "148")
        var uptime: UInt64 = 0
        var quitCount = 0
        let selected = await NativeAgentLauncher.resolveTargetHelper(
            currentURL: currentURL,
            deadline: UInt64.max,
            isPending: { true },
            helpers: {
                [self.runtimeHelper(
                    processIdentifier: 811,
                    bundleURL: currentURL,
                    launchDate: Date(timeIntervalSince1970: 11_000),
                    requestQuit: {
                        quitCount += 1
                        return false
                    }
                )]
            },
            identity: { _ in nil },
            validate: { _ in true },
            uptime: { uptime },
            sleep: { uptime += $0 }
        )

        XCTAssertNil(selected)
        XCTAssertEqual(quitCount, 1)
    }

    func testNativeAgentResolutionLaunchesAfterLegacyRuntimeExits() async throws {
        let currentURL = try makeAmbientBundle(name: "Legacy", build: "149")
        let launchDate = Date(timeIntervalSince1970: 11_500)
        var uptime: UInt64 = 0
        var isLegacyRunning = true
        var requestCount = 0
        let selected = await NativeAgentLauncher.resolveTargetHelper(
            currentURL: currentURL,
            deadline: UInt64.max,
            isPending: { true },
            helpers: {
                guard isLegacyRunning else { return [] }
                return [self.runtimeHelper(
                    processIdentifier: 812,
                    bundleURL: currentURL,
                    launchDate: launchDate,
                    isRunning: { isLegacyRunning },
                    requestQuit: {
                        requestCount += 1
                        isLegacyRunning = false
                        return true
                    }
                )]
            },
            identity: { _ in nil },
            validate: { _ in true },
            uptime: { uptime },
            sleep: { uptime += $0 }
        )

        guard let selected,
              case .launch(let selectedURL, let createsNewInstance) = selected
        else { return XCTFail("Expected fresh helper launch") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertFalse(createsNewInstance)
        XCTAssertEqual(requestCount, 1)
    }

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
        let selected = await NativeAgentLauncher.resolveTargetHelper(
            currentURL: currentURL,
            deadline: UInt64.max,
            isPending: { true },
            helpers: {
                guard isRunning else { return [] }
                return [self.runtimeHelper(
                    processIdentifier: 813,
                    bundleURL: currentURL,
                    launchDate: launchDate,
                    requestQuit: {
                        quitCount += 1
                        isRunning = false
                        return true
                    }
                )]
            },
            identity: { _ in
                identityReadCount += 1
                if uptime >= 350_000_000 {
                    publishedIdentity = identity
                }
                return publishedIdentity
            },
            validate: { _ in true },
            uptime: { uptime },
            sleep: { uptime += $0 }
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

    func testNativeAgentResolutionRechecksIdentityBeforeUnknownRetirement()
        async throws {
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
        let selected = await NativeAgentLauncher.resolveTargetHelper(
            currentURL: currentURL,
            deadline: UInt64.max,
            isPending: { true },
            helpers: {
                [self.runtimeHelper(
                    processIdentifier: 817,
                    bundleURL: currentURL,
                    launchDate: launchDate,
                    requestQuit: {
                        quitCount += 1
                        return true
                    }
                )]
            },
            identity: { _ in
                guard uptime >= 1_000_000_000 else { return nil }
                boundaryReadCount += 1
                return boundaryReadCount > 1 ? identity : nil
            },
            validate: { _ in true },
            uptime: { uptime },
            sleep: { uptime += $0 }
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

    func testNativeAgentResolutionPreservesUnknownOtherPath() async throws {
        let currentURL = try makeAmbientBundle(name: "Current", build: "149")
        let otherURL = try makeAmbientBundle(name: "Other Legacy", build: "148")
        var quitCount = 0
        let selected = await NativeAgentLauncher.resolveTargetHelper(
            currentURL: currentURL,
            deadline: UInt64.max,
            isPending: { true },
            helpers: {
                [self.runtimeHelper(
                    processIdentifier: 814,
                    bundleURL: otherURL,
                    launchDate: Date(timeIntervalSince1970: 11_700),
                    requestQuit: {
                        quitCount += 1
                        return true
                    }
                )]
            },
            identity: { _ in nil },
            validate: { _ in true }
        )

        guard let selected,
              case .launch(let selectedURL, let createsNewInstance) = selected
        else { return XCTFail("Expected fresh helper launch") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertFalse(createsNewInstance)
        XCTAssertEqual(quitCount, 0)
    }

    func testUnknownSamePathRetirementPreservesUnknownOtherPath()
        async throws {
        let currentURL = try makeAmbientBundle(name: "Current", build: "149")
        let otherURL = try makeAmbientBundle(name: "Other Legacy", build: "148")
        let launchDate = Date(timeIntervalSince1970: 11_800)
        var uptime: UInt64 = 0
        var samePathIsRunning = true
        var samePathQuitCount = 0
        var otherPathQuitCount = 0
        let selected = await NativeAgentLauncher.resolveTargetHelper(
            currentURL: currentURL,
            deadline: UInt64.max,
            isPending: { true },
            helpers: {
                var result = [self.runtimeHelper(
                    processIdentifier: 815,
                    bundleURL: otherURL,
                    launchDate: launchDate,
                    requestQuit: {
                        otherPathQuitCount += 1
                        return true
                    }
                )]
                if samePathIsRunning {
                    result.append(self.runtimeHelper(
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
            validate: { _ in true },
            uptime: { uptime },
            sleep: { uptime += $0 }
        )

        guard let selected,
              case .launch(let selectedURL, let createsNewInstance) = selected
        else { return XCTFail("Expected fresh helper launch") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertFalse(createsNewInstance)
        XCTAssertEqual(samePathQuitCount, 1)
        XCTAssertEqual(otherPathQuitCount, 0)
    }

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
        let selected = await NativeAgentLauncher.resolveTargetHelper(
            currentURL: currentURL,
            deadline: UInt64.max,
            isPending: { true },
            helpers: {
                guard isRunning else { return [] }
                return [self.runtimeHelper(
                    processIdentifier: 821,
                    bundleURL: currentURL,
                    launchDate: launchDate,
                    isRunning: { isRunning },
                    requestQuit: {
                        quitCount += 1
                        return true
                    }
                )]
            },
            identity: { _ in identity },
            validate: { _ in true },
            sleep: { _ in isRunning = false }
        )

        guard let selected,
              case .launch(let selectedURL, let createsNewInstance) = selected
        else { return XCTFail("Expected launch target") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertFalse(createsNewInstance)
        XCTAssertEqual(quitCount, 1)
    }

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
        let selected = await NativeAgentLauncher.resolveTargetHelper(
            currentURL: currentURL,
            deadline: UInt64.max,
            isPending: { true },
            helpers: {
                var result = [
                    self.runtimeHelper(
                        processIdentifier: 831,
                        bundleURL: currentURL,
                        launchDate: launchDate
                    ),
                ]
                if incompatibleIsRunning {
                    result.append(self.runtimeHelper(
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
            validate: { _ in true },
            sleep: { _ in incompatibleIsRunning = false }
        )

        guard let selected, case .running(
                  let selectedURL,
                  let processIdentifier,
                  let runtimeInstanceIdentifier
              ) = selected else { return XCTFail("Expected running target") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertEqual(processIdentifier, 831)
        XCTAssertEqual(
            runtimeInstanceIdentifier,
            compatible.instanceIdentifier
        )
        XCTAssertEqual(quitCount, 1)
    }

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

        let selected = await NativeAgentLauncher.resolveTargetHelper(
            currentURL: currentURL,
            deadline: UInt64.max,
            isPending: { true },
            helpers: {
                guard isRunning else { return [] }
                return [self.runtimeHelper(
                    processIdentifier: 833,
                    bundleURL: currentURL,
                    launchDate: launchDate,
                    isRunning: { isRunning },
                    requestQuit: {
                        quitCount += 1
                        return true
                    }
                )]
            },
            identity: { _ in identity },
            validate: { _ in true },
            sleep: { _ in isRunning = false }
        )

        guard let selected,
              case .launch(let selectedURL, let createsNewInstance) = selected
        else { return XCTFail("Expected a fresh helper launch") }
        XCTAssertEqual(selectedURL, currentURL)
        XCTAssertFalse(createsNewInstance)
        XCTAssertEqual(quitCount, 1)
    }

    func testNativeAgentResolutionFailsClosedWhenRetirementIsRefused()
        async throws {
        let currentURL = try makeAmbientBundle(name: "Refuses Quit", build: "149")
        let launchDate = Date(timeIntervalSince1970: 13_550)
        let identity = try runtimeIdentity(
            processIdentifier: 835,
            bundleURL: currentURL,
            launchDate: launchDate,
            runtimeProtocolVersion: 2
        )
        var quitCount = 0

        let selected = await NativeAgentLauncher.resolveTargetHelper(
            currentURL: currentURL,
            deadline: UInt64.max,
            isPending: { true },
            helpers: {
                [self.runtimeHelper(
                    processIdentifier: 835,
                    bundleURL: currentURL,
                    launchDate: launchDate,
                    requestQuit: {
                        quitCount += 1
                        return false
                    }
                )]
            },
            identity: { _ in identity },
            validate: { _ in true }
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

        XCTAssertFalse(NativeAgentLauncher.isCompatibleRuntimeIdentity(
            identity,
            runtimeURL: otherURL,
            expectedURL: expectedURL
        ))
        XCTAssertTrue(NativeAgentLauncher.isCompatibleRuntimeIdentity(
            identity,
            runtimeURL: otherURL,
            expectedURL: otherURL
        ))
    }

    @MainActor
    func testReceiptOwnerMetadataIgnoresUnidentifiedOtherPath() throws {
        let expectedURL = try makeAmbientBundle(name: "Expected", build: "149")
        let otherURL = try makeAmbientBundle(name: "Other Legacy", build: "148")
        let version = try XCTUnwrap(
            AmbientRuntimeIdentity.bundleVersion(at: expectedURL)
        )
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: .init(value: UUID()),
            runtimeInstanceIdentifier: UUID(),
            owner: try nativeDeliveryOwner(bundleURL: expectedURL)
        )

        let status = NativeAgentLauncher.runtimeStatus(
            receipt: receipt,
            expectedURL: expectedURL,
            expectedVersion: version,
            helpers: {
                [self.runtimeHelper(
                    processIdentifier: 836,
                    bundleURL: otherURL,
                    launchDate: Date(timeIntervalSince1970: 13_700)
                )]
            },
            identity: { _ in nil },
            validate: { $0 == expectedURL }
        )

        guard case .absent = status else {
            return XCTFail("Unrelated helper must not fence recovery")
        }
    }

    @MainActor
    func testReceiptOwnerMetadataRetainsTrueUnknownOwnerAmbiguity() throws {
        let expectedURL = try makeAmbientBundle(name: "Expected", build: "149")
        let version = try XCTUnwrap(
            AmbientRuntimeIdentity.bundleVersion(at: expectedURL)
        )
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: .init(value: UUID()),
            runtimeInstanceIdentifier: UUID(),
            owner: try nativeDeliveryOwner(bundleURL: expectedURL)
        )

        let status = NativeAgentLauncher.runtimeStatus(
            receipt: receipt,
            expectedURL: expectedURL,
            expectedVersion: version,
            helpers: {
                [self.runtimeHelper(
                    processIdentifier: 837,
                    bundleURL: expectedURL,
                    launchDate: Date(timeIntervalSince1970: 13_800)
                )]
            },
            identity: { _ in nil },
            validate: { $0 == expectedURL }
        )

        guard case .indeterminate = status else {
            return XCTFail("Possible owner must remain ambiguous")
        }
    }

    @MainActor
    func testOwnerlessReceiptRetainsCrossPathAmbiguity() throws {
        let expectedURL = try makeAmbientBundle(name: "Expected", build: "149")
        let otherURL = try makeAmbientBundle(name: "Other", build: "148")
        let version = try XCTUnwrap(
            AmbientRuntimeIdentity.bundleVersion(at: expectedURL)
        )
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: .init(value: UUID()),
            runtimeInstanceIdentifier: UUID()
        )

        let status = NativeAgentLauncher.runtimeStatus(
            receipt: receipt,
            expectedURL: expectedURL,
            expectedVersion: version,
            helpers: {
                [self.runtimeHelper(
                    processIdentifier: 838,
                    bundleURL: otherURL,
                    launchDate: Date(timeIntervalSince1970: 13_900)
                )]
            },
            identity: { _ in nil },
            validate: { $0 == expectedURL }
        )

        guard case .indeterminate = status else {
            return XCTFail("Legacy receipt must fail closed")
        }
    }

    @MainActor
    func testNativeAgentClearsReceiptWhoseRuntimeIsAbsent() async throws {
        let fixture = try makeFixture(id: 824)
        let helperURL = try makeAmbientBundle(name: "Receipt Owner", build: "149")
        let owner = try nativeDeliveryOwner(bundleURL: helperURL)
        let admission = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let runtimeInstanceIdentifier = UUID()
        let recorded = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier,
            owner: owner
        )
        XCTAssertEqual(recorded, .persisted)
        var clearCount = 0
        let dependencies = NativeAgentLauncher.ApprovalDeliveryDependencies(
            load: { handle in await self.bridge.load(handle: handle) },
            receiptRuntimeStatus: { receipt in
                XCTAssertEqual(
                    receipt.runtimeInstanceIdentifier,
                    runtimeInstanceIdentifier
                )
                XCTAssertEqual(receipt.owner, owner)
                return .absent
            },
            clearReceipt: { handle, receipt in
                clearCount += 1
                return await self.bridge.clearNativeDeliveryReceipt(
                    handle: handle,
                    nativeDeliveryNonce: receipt.nativeDeliveryNonce,
                    runtimeInstanceIdentifier:
                        receipt.runtimeInstanceIdentifier
                )
            },
            wait: { _ in }
        )

        let status = await NativeAgentLauncher.approvalDeliveryStatus(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            isPending: { true },
            dependencies: dependencies
        )

        XCTAssertEqual(status, .needsDelivery)
        XCTAssertEqual(clearCount, 1)
        guard case .found(let snapshot) = await bridge.load(
            handle: admission.handle
        ) else { return XCTFail("Expected retained request") }
        XCTAssertNil(snapshot.nativeDeliveryReceipt)
    }

    @MainActor
    func testNativeAgentQuitsIncompatibleReceiptOwnerBeforeClearing()
        async throws {
        let fixture = try makeFixture(id: 825)
        let admission = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let runtimeInstanceIdentifier = UUID()
        let recorded = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: runtimeInstanceIdentifier
        )
        XCTAssertEqual(recorded, .persisted)
        var events = [String]()
        var loadCount = 0
        var isRunning = true
        let owner = NativeAgentLauncher.ExactReceiptOwner(
            requestQuit: {
                events.append("quit")
                return true
            },
            isRunning: {
                events.append("running")
                return isRunning
            }
        )
        let dependencies = NativeAgentLauncher.ApprovalDeliveryDependencies(
            load: { handle in
                loadCount += 1
                return await self.bridge.load(handle: handle)
            },
            runtimeStatus: { instanceIdentifier in
                XCTAssertEqual(instanceIdentifier, runtimeInstanceIdentifier)
                return .incompatible(owner)
            },
            clearReceipt: { handle, receipt in
                events.append("clear")
                return await self.bridge.clearNativeDeliveryReceipt(
                    handle: handle,
                    nativeDeliveryNonce: receipt.nativeDeliveryNonce,
                    runtimeInstanceIdentifier:
                        receipt.runtimeInstanceIdentifier
                )
            },
            wait: { _ in
                events.append("wait")
                isRunning = false
            }
        )

        let status = await NativeAgentLauncher.approvalDeliveryStatus(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            isPending: { true },
            dependencies: dependencies
        )

        XCTAssertEqual(status, .needsDelivery)
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(events, ["quit", "running", "wait", "running", "clear"])
    }

    @MainActor
    func testNativeAgentRechecksChangedReceiptBeforeQuitting() async throws {
        let fixture = try makeFixture(id: 826)
        let admission = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let firstRuntime = UUID()
        let recorded = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: firstRuntime
        )
        XCTAssertEqual(recorded, .persisted)
        guard case .found(let firstSnapshot) = await bridge.load(
            handle: admission.handle
        ) else { return XCTFail("Expected native receipt") }
        let secondRuntime = UUID()
        let secondReceipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: secondRuntime
        )
        let secondSnapshot = ExtensionBridge.Snapshot(
            handle: firstSnapshot.handle,
            phase: firstSnapshot.phase,
            request: firstSnapshot.request,
            nativeDecisionStaged: firstSnapshot.nativeDecisionStaged,
            nativeDeliveryNonce: firstSnapshot.nativeDeliveryNonce,
            nativeDeliveryReceipt: secondReceipt,
            host: firstSnapshot.host,
            configurationKey: firstSnapshot.configurationKey,
            revisions: firstSnapshot.revisions,
            createdAt: firstSnapshot.createdAt,
            enqueueAttempt: firstSnapshot.enqueueAttempt,
            sequence: firstSnapshot.sequence
        )
        var loadCount = 0
        var quitCount = 0
        var clearCount = 0
        let owner = NativeAgentLauncher.ExactReceiptOwner(
            requestQuit: {
                quitCount += 1
                return true
            },
            isRunning: { false }
        )
        let dependencies = NativeAgentLauncher.ApprovalDeliveryDependencies(
            load: { _ in
                loadCount += 1
                return .found(loadCount == 1 ? firstSnapshot : secondSnapshot)
            },
            runtimeStatus: { instanceIdentifier in
                instanceIdentifier == firstRuntime
                    ? .incompatible(owner)
                    : .compatible(.running(
                        url: self.rootURL.appendingPathComponent("Owner.app"),
                        processIdentifier: 840,
                        runtimeInstanceIdentifier: secondRuntime
                    ))
            },
            clearReceipt: { _, _ in
                clearCount += 1
                return .persisted
            },
            wait: { _ in }
        )

        let status = await NativeAgentLauncher.approvalDeliveryStatus(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            isPending: { true },
            dependencies: dependencies
        )

        XCTAssertEqual(status, .delivered)
        XCTAssertEqual(loadCount, 3)
        XCTAssertEqual(quitCount, 0)
        XCTAssertEqual(clearCount, 0)
    }

    @MainActor
    func testNativeAgentRetainsReceiptForUnidentifiedRuntime() async throws {
        let fixture = try makeFixture(id: 827)
        let admission = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let recorded = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID()
        )
        XCTAssertEqual(recorded, .persisted)
        var clearCount = 0
        let dependencies = NativeAgentLauncher.ApprovalDeliveryDependencies(
            load: { handle in await self.bridge.load(handle: handle) },
            runtimeStatus: { _ in .indeterminate },
            clearReceipt: { _, _ in
                clearCount += 1
                return .persisted
            },
            wait: { _ in }
        )

        let status = await NativeAgentLauncher.approvalDeliveryStatus(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            isPending: { true },
            dependencies: dependencies
        )

        XCTAssertEqual(status, .unavailable)
        XCTAssertEqual(clearCount, 0)
        guard case .found(let snapshot) = await bridge.load(
            handle: admission.handle
        ) else { return XCTFail("Expected retained request") }
        XCTAssertNotNil(snapshot.nativeDeliveryReceipt)
    }

    @MainActor
    func testNativeAgentReactivationTargetsReceiptOwnerAndKeepsPollingSilent()
        async throws {
        let fixture = try makeFixture(id: 839)
        let admission = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let helperURL = try makeAmbientBundle(name: "Reactivation", build: "149")
        let launchDate = Date(timeIntervalSince1970: 14_000)
        let unrelated = try runtimeIdentity(
            processIdentifier: 839,
            bundleURL: helperURL,
            launchDate: launchDate
        )
        let owner = try runtimeIdentity(
            processIdentifier: 840,
            bundleURL: helperURL,
            launchDate: launchDate
        )
        let recorded = await bridge.recordNativeDeliveryReceipt(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: owner.instanceIdentifier,
            owner: try nativeDeliveryOwner(bundleURL: helperURL)
        )
        XCTAssertEqual(recorded, .persisted)
        let dependencies = NativeAgentLauncher.ApprovalDeliveryDependencies(
            load: { await self.bridge.load(handle: $0) },
            receiptRuntimeStatus: { receipt in
                NativeAgentLauncher.runtimeStatus(
                    receipt: receipt,
                    expectedURL: helperURL,
                    expectedVersion: owner.version,
                    helpers: {
                        [unrelated, owner].map { runtime in
                            self.runtimeHelper(
                                processIdentifier: runtime.processIdentifier,
                                bundleURL: helperURL,
                                launchDate: launchDate
                            )
                        }
                    },
                    identity: { $0 == owner.processIdentifier ? owner : unrelated },
                    validate: { $0 == helperURL }
                )
            },
            clearReceipt: { _, _ in
                XCTFail("Compatible owner must retain its receipt")
                return .ownershipLost
            },
            wait: { _ in }
        )
        let route = NativeAgentRoute.approval(
            workflowVersion: ExtensionBridge.workflowVersion,
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce
        )
        var targets = [NativeAgentLauncher.HelperTarget]()
        var deliveredRoutes = [URL]()
        let launcher = NativeAgentLauncher(
            helperURL: { helperURL },
            validate: { $0 == helperURL },
            resolveHelper: { _, _, _ in
                XCTFail("Existing approval must target its receipt owner")
                return nil
            },
            existingDelivery: { _, isPending in
                await NativeAgentLauncher.approvalDeliveryStatus(
                    handle: admission.handle,
                    nativeDeliveryNonce: admission.nativeDeliveryNonce,
                    isPending: isPending,
                    dependencies: dependencies
                )
            },
            launch: { target, url, completion in
                targets.append(target)
                deliveredRoutes.append(url)
                completion(true)
            }
        )

        let delivered = await launcher.open(route)
        XCTAssertTrue(delivered)
        XCTAssertTrue(targets.isEmpty)
        let reactivated = await launcher.reactivate(route, dependencies: dependencies)
        XCTAssertTrue(reactivated)
        XCTAssertEqual(targets, [.running(
            url: helperURL,
            processIdentifier: owner.processIdentifier,
            runtimeInstanceIdentifier: owner.instanceIdentifier
        )])
        XCTAssertEqual(deliveredRoutes, [route.url])

        let wrongNonce = await launcher.reactivate(.approval(
            workflowVersion: ExtensionBridge.workflowVersion,
            handle: admission.handle,
            nativeDeliveryNonce: .init(value: UUID())
        ), dependencies: dependencies)
        XCTAssertFalse(wrongNonce)
        let rejected = await bridge.rejectNativeDelivery(
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce,
            runtimeInstanceIdentifier: owner.instanceIdentifier
        )
        XCTAssertEqual(rejected, .persisted)
        let completed = await launcher.reactivate(route, dependencies: dependencies)
        XCTAssertFalse(completed)
        XCTAssertEqual(deliveredRoutes, [route.url])
    }

    @MainActor
    func testNativeAgentReactivationDeliversApprovalWithoutReceipt() async throws {
        let fixture = try makeFixture(id: 840)
        let admission = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        ))
        let helperURL = try makeAmbientBundle(name: "Undelivered", build: "149")
        let route = NativeAgentRoute.approval(
            workflowVersion: ExtensionBridge.workflowVersion,
            handle: admission.handle,
            nativeDeliveryNonce: admission.nativeDeliveryNonce
        )
        let dependencies = NativeAgentLauncher.ApprovalDeliveryDependencies(
            load: { await self.bridge.load(handle: $0) },
            runtimeStatus: { _ in
                XCTFail("Undelivered request has no owner to resolve")
                return .absent
            },
            clearReceipt: { _, _ in
                XCTFail("Undelivered request has no receipt to clear")
                return .ownershipLost
            },
            wait: { _ in }
        )
        var deliveredRoutes = [URL]()
        let launcher = NativeAgentLauncher(
            helperURL: { helperURL },
            validate: { $0 == helperURL },
            launch: { target, url, completion in
                XCTAssertEqual(target, .launch(
                    url: helperURL,
                    createsNewApplicationInstance: false
                ))
                deliveredRoutes.append(url)
                completion(true)
            }
        )

        let reactivated = await launcher.reactivate(route, dependencies: dependencies)
        XCTAssertTrue(reactivated)
        XCTAssertEqual(deliveredRoutes, [route.url])
    }

    func testNativeAgentLaunchTimesOutDuringResolution() async throws {
        let helperURL = try makeAmbientBundle(name: "Timeout", build: "148")
        var launchCount = 0
        let launcher = NativeAgentLauncher(
            helperURL: { helperURL },
            validate: { _ in true },
            resolveHelper: { url, _, _ in
                try? await Task.sleep(nanoseconds: 50_000_000)
                return .launch(
                    url: url,
                    createsNewApplicationInstance: false
                )
            },
            launchTimeoutNanoseconds: 1_000_000,
            launch: { _, _, _ in launchCount += 1 }
        )

        let opened = await launcher.open(.showWallet(
            workflowVersion: ExtensionBridge.workflowVersion
        ))
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertFalse(opened)
        XCTAssertEqual(launchCount, 0)
    }

    func testNativeAgentLaunchTimesOutWhenLaunchServicesNeverCompletes() async throws {
        let helperURL = try makeAmbientBundle(name: "Launch", build: "148")
        var launchCompletion: ((Bool) -> Void)?
        let launcher = NativeAgentLauncher(
            helperURL: { helperURL },
            validate: { _ in true },
            resolveHelper: { url, _, _ in
                .launch(url: url, createsNewApplicationInstance: false)
            },
            launchTimeoutNanoseconds: 1_000_000,
            launch: { _, _, completion in
                launchCompletion = completion
            }
        )

        let opened = await launcher.open(.showWallet(
            workflowVersion: ExtensionBridge.workflowVersion
        ))
        launchCompletion?(true)

        XCTAssertFalse(opened)
    }

    func testNativeAgentLaunchRequiresCompatibleRuntimeConfirmation() async throws {
        let helperURL = try makeAmbientBundle(name: "Confirm", build: "148")
        let launcher = NativeAgentLauncher(
            helperURL: { helperURL },
            validate: { _ in true },
            resolveHelper: { url, _, _ in
                .launch(url: url, createsNewApplicationInstance: false)
            },
            confirm: { _, _, _, _ in false },
            launchTimeoutNanoseconds: 50_000_000,
            launch: { _, _, completion in completion(true) }
        )

        let opened = await launcher.open(.showWallet(
            workflowVersion: ExtensionBridge.workflowVersion
        ))

        XCTAssertFalse(opened)
    }

    func testNativeAgentLaunchRetriesTheIdenticalApprovalDelivery() async throws {
        let helperURL = try makeAmbientBundle(name: "Retry", build: "148")
        let handle = ExtensionBridge.Handle(
            id: 823,
            token: .init(value: UUID()),
            profileIdentifier: nil
        )
        let route = NativeAgentRoute.approval(
            workflowVersion: ExtensionBridge.workflowVersion,
            handle: handle,
            nativeDeliveryNonce: .init(value: UUID())
        )
        var confirmations = 0
        var resolutions = 0
        var preflights = 0
        var delivered = [URL]()
        var events = [String]()
        let launcher = NativeAgentLauncher(
            helperURL: { helperURL },
            validate: { _ in true },
            resolveHelper: { url, _, _ in
                events.append("resolve")
                resolutions += 1
                return .launch(
                    url: url,
                    createsNewApplicationInstance: false
                )
            },
            confirm: { _, confirmedRoute, _, _ in
                XCTAssertEqual(confirmedRoute, route)
                events.append("confirm")
                confirmations += 1
                return confirmations == 2
            },
            existingDelivery: { checkedRoute, _ in
                XCTAssertEqual(checkedRoute, route)
                events.append("preflight")
                preflights += 1
                return .needsDelivery
            },
            launchTimeoutNanoseconds: 50_000_000,
            launch: { _, deliveredRoute, completion in
                events.append("send")
                delivered.append(deliveredRoute)
                completion(true)
            }
        )

        let opened = await launcher.open(route)
        XCTAssertTrue(opened)
        XCTAssertEqual(preflights, 2)
        XCTAssertEqual(resolutions, 2)
        XCTAssertEqual(confirmations, 2)
        XCTAssertEqual(delivered, [route.url, route.url])
        XCTAssertEqual(events, [
            "preflight", "resolve", "send", "confirm",
            "preflight", "resolve", "send", "confirm",
        ])
    }

    func testNativeAgentConfirmationStopsAtOuterDeadline() async throws {
        let helperURL = try makeAmbientBundle(name: "ConfirmTimeout", build: "148")
        let confirmationStopped = expectation(
            description: "confirmation stopped at the outer deadline"
        )
        let launcher = NativeAgentLauncher(
            helperURL: { helperURL },
            validate: { _ in true },
            resolveHelper: { url, _, _ in
                .launch(url: url, createsNewApplicationInstance: false)
            },
            confirm: { _, _, deadline, isPending in
                while isPending(),
                      DispatchTime.now().uptimeNanoseconds < deadline {
                    await Task.yield()
                }
                confirmationStopped.fulfill()
                return false
            },
            launchTimeoutNanoseconds: 50_000_000,
            launch: { _, _, completion in completion(true) }
        )

        let opened = await launcher.open(.showWallet(
            workflowVersion: ExtensionBridge.workflowVersion
        ))
        await fulfillment(of: [confirmationStopped], timeout: 1)

        XCTAssertFalse(opened)
    }

    func testSeparateProcessStoreLockFencesAccess() async throws {
        let fixture = try makeFixture(id: 80)
        let readyURL = rootURL.appendingPathComponent("holder-ready")
        let lockURL = rootURL.appendingPathComponent("bridge-v6.lock")
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
        bundleURL: URL
    ) throws -> ExtensionBridge.NativeDeliveryOwner {
        let version = try XCTUnwrap(
            AmbientRuntimeIdentity.bundleVersion(at: bundleURL)
        )
        return try XCTUnwrap(ExtensionBridge.NativeDeliveryOwner(
            bundleURL: bundleURL,
            marketingVersion: version.marketing,
            buildVersion: version.build
        ))
    }

    private func runtimeHelper(
        processIdentifier: Int32,
        bundleURL: URL,
        launchDate: Date,
        isRunning: @escaping () -> Bool = { true },
        requestQuit: @escaping () -> Bool = { false }
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

    private func makeNativeDecisionExecutable(
        handle: ExtensionBridge.Handle,
        configurationKey: String,
        revisions: ExtensionBridge.ProviderRevisions
    ) async throws -> (
        context: ExtensionBridge.NativeExecutionContext,
        fence: ExtensionBridge.NativeExecutionFence
    ) {
        let fenceToken = UUID()
        let acquiredFence = await bridge.acquireNativeExecutionFence(
            handle: handle,
            token: fenceToken
        )
        let fence = try XCTUnwrap(acquiredFence)
        let context: ExtensionBridge.NativeExecutionContext
        switch await bridge.recordNativeExecutionContext(
            handle: handle,
            configurationKey: configurationKey,
            revisions: revisions,
            executionDeadline: clock.now.addingTimeInterval(120),
            fenceToken: fenceToken
        ) {
        case .recorded(let value):
            context = value
        case .pending, .responseReady, .missing, .unavailable:
            throw Failure.expectedValue
        }
        return (context, fence)
    }

    private func makeExecutableNativePermit(
        id: Int
    ) async throws -> (
        request: SafariRequest,
        handle: ExtensionBridge.Handle,
        context: ExtensionBridge.NativeExecutionContext,
        fence: ExtensionBridge.NativeExecutionFence,
        permit: ExtensionBridge.ExecutionPermit
    ) {
        let fixture = try makeFixture(id: id)
        let handle = try accepted(await bridge.enqueue(
            ingress: fixture.ingress,
            profileIdentifier: nil
        )).handle
        let staged = await bridge.stageNativeDecision(
            handle: handle,
            decision: .message(.init(solanaCluster: nil))
        )
        XCTAssertEqual(staged, .persisted)
        let execution = try await makeNativeDecisionExecutable(
            handle: handle,
            configurationKey: fixture.request.configurationKey,
            revisions: try XCTUnwrap(.init(rawValue: [
                "ethereum": 0,
                "solana": 0,
            ]))
        )
        let nativeClaim: ExtensionBridge.NativeDecisionClaim
        switch await bridge.claimExecutableNativeDecision(handle: handle) {
        case .claimed(let value):
            nativeClaim = value
        case .notStaged, .executing, .responded, .missing, .unavailable:
            throw Failure.expectedValue
        }
        let permit = try executionPermit(await bridge.begin(
            claim: nativeClaim.approvalClaim
        ))
        return (
            fixture.request,
            handle,
            execution.context,
            execution.fence,
            permit
        )
    }

    private func makeManualFixture(
        id: Int,
        enqueueAttempt: String,
        latestConfigurations: [[String: Any]],
        revisions: [String: Int]
    ) throws -> Fixture {
        let object: [String: Any] = [
            "id": id,
            "name": "switchAccount",
            "provider": "unknown",
            "host": "wallet.example",
            "configurationKey": "https://wallet.example",
            "enqueueAttempt": enqueueAttempt,
            "admissionDeadline": Int(
                clock.now.addingTimeInterval(
                    ExtensionBridge.requestTTL
                ).timeIntervalSince1970 * 1_000
            ),
            "workflowVersion": ExtensionBridge.workflowVersion,
            "favicon": "",
            "revisions": revisions,
            "body": ["latestConfigurations": latestConfigurations],
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
            revisions,
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
            payload: .body(.ethereum(.init(result: largeResponseResult)))
        )
    }

    private func fillCompletedByteCapacity(
        startingID: Int = 0,
        host: String? = nil
    ) async throws -> [(fixture: Fixture, handle: ExtensionBridge.Handle)] {
        var completed = [(fixture: Fixture, handle: ExtensionBridge.Handle)]()
        for id in startingID..<(startingID + 64) {
            let fixture = try makeFixture(id: id, host: host ?? "capacity-\(id).example")
            let result = await bridge.enqueue(ingress: fixture.ingress, profileIdentifier: nil)
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
            .appendingPathComponent("profiles-v6", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("state")
    }

    private func operationLockURL(_ handle: ExtensionBridge.Handle) -> URL {
        let profile = handle.profileIdentifier?.uuidString.lowercased() ?? "default"
        return rootURL
            .appendingPathComponent("operation-locks-v6", isDirectory: true)
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
