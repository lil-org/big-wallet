import Foundation
import Synchronization
import WalletAuthority
import WalletDomain
import WalletRuntimeTestSupport
import XCTest
@testable import WalletFlows

@MainActor
final class NativeIngressGateTests: XCTestCase {
    private static let host = "wallet.example"
    private static let origin = "https://wallet.example"
    private static let documentSession = String(repeating: "a", count: 32)
    private static let requestToken = "00000000-0000-4000-8000-000000000001"

    func testPayloadAndContextTextBudgetsAcceptExactBytesAndRejectOneLess() throws {
        let raw = normal()
        var limits = NativeIngressGate.Limits()
        limits.maximumPayloadTextBytes = payloadTextBytes
        limits.maximumContextTextBytes = contextTextBytes
        let exact = NativeIngressGate(limits: limits)
        let admitted = try exact.admit(raw, profileIdentifier: nil)
        XCTAssertEqual(exact.statistics.retainedBytes, payloadTextBytes + contextTextBytes + 29 * 64)
        admitted.finish()
        assertDrained(exact)

        limits.maximumPayloadTextBytes -= 1
        let payloadLimited = NativeIngressGate(limits: limits)
        assertRejected(payloadLimited, raw, reason: .requestTooLarge)
        assertDrained(payloadLimited)

        limits.maximumPayloadTextBytes += 1
        limits.maximumContextTextBytes -= 1
        let contextLimited = NativeIngressGate(limits: limits)
        assertRejected(contextLimited, raw, reason: .requestTooLarge)
        assertDrained(contextLimited)
    }

    func testContextBudgetCountsUTF8IndependentlyOfPayloadText() throws {
        var limits = NativeIngressGate.Limits()
        limits.maximumPayloadTextBytes = payloadTextBytes
        limits.maximumContextTextBytes = contextTextBytes + "documentId".utf8.count + "🦊".utf8.count
        let raw = normal(documentID: "🦊")
        let exact = NativeIngressGate(limits: limits)
        let admitted = try exact.admit(raw, profileIdentifier: nil)
        admitted.finish()
        assertDrained(exact)

        limits.maximumContextTextBytes -= 1
        let limited = NativeIngressGate(limits: limits)
        assertRejected(limited, raw, reason: .requestTooLarge)
        assertDrained(limited)
    }

    func testEncodedPayloadLimitIncludesEscapingButExcludesTheTransportContext() throws {
        let raw = dapp(object: ["text": String(repeating: "\u{01}", count: 16)])
        var payload = raw
        payload.removeValue(forKey: WireProtocol.nativeContextKey)
        let encodedBytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).count
        var limits = NativeIngressGate.Limits()
        limits.maximumPayloadBytes = encodedBytes
        let exact = NativeIngressGate(limits: limits)
        let admitted = try exact.admit(raw, profileIdentifier: nil)
        admitted.finish()
        assertDrained(exact)

        limits.maximumPayloadBytes -= 1
        let limited = NativeIngressGate(limits: limits)
        assertRejected(limited, raw, reason: .requestTooLarge)
        assertDrained(limited)
    }

    func testNodeBudgetCountsKeysValuesAndContainersAtItsExactBoundary() throws {
        var limits = NativeIngressGate.Limits()
        limits.maximumNodes = 29
        let exact = NativeIngressGate(limits: limits)
        let admitted = try exact.admit(normal(), profileIdentifier: nil)
        admitted.finish()
        assertDrained(exact)

        limits.maximumNodes = 28
        let limited = NativeIngressGate(limits: limits)
        assertRejected(limited, normal(), reason: .requestTooComplex)
        assertDrained(limited)
    }

    func testDepthLimitIncludesTheRootAndAcceptsTheWireMaximum() throws {
        var limits = NativeIngressGate.Limits()
        limits.maximumDepth = 3
        let exact = NativeIngressGate(limits: limits)
        let admitted = try exact.admit(normal(), profileIdentifier: nil)
        admitted.finish()

        limits.maximumDepth = 2
        let limited = NativeIngressGate(limits: limits)
        assertRejected(limited, normal(), reason: .requestTooComplex)
        assertDrained(limited)

        let wireLimit = NativeIngressGate()
        let deep = try wireLimit.admit(dapp(object: ["nested": nestedArrays(61)]), profileIdentifier: nil)
        deep.finish()
        assertRejected(wireLimit, dapp(object: ["nested": nestedArrays(62)]), reason: .requestTooComplex)
        assertDrained(wireLimit)
    }

    func testBroadFoundationArrayIsRejectedBeforeReadingItsElements() {
        var limits = NativeIngressGate.Limits()
        limits.maximumNodes = 64
        let gate = NativeIngressGate(limits: limits)
        let values = ReadCountingArray(reportedCount: 1_000)

        assertRejected(gate, dapp(object: ["values": values]), reason: .requestTooComplex)

        XCTAssertEqual(values.elementReads, 0)
        assertDrained(gate)
    }

    func testRawFoundationUnicodeKeyCollisionsCannotBecomeValidCommands() throws {
        let contextData = try JSONSerialization.data(withJSONObject: context())
        let contextJSON = try XCTUnwrap(String(data: contextData, encoding: .utf8))
        for fields in [
            "\"configurationKey\":\"\(Self.origin)\",\"configurationKey\":\"\(Self.origin)\"",
            "\"configurationKey\":\"\(Self.origin)\",\"configurationKey\":\"\(Self.origin)\"",
        ] {
            let data = Data("{\"id\":1,\"workflowVersion\":\(WireProtocol.workflowVersion),\"subject\":\"getLatestConfiguration\",\(fields),\"__bwContext\":\(contextJSON)}".utf8)
            let raw = try JSONSerialization.jsonObject(with: data)
            let gate = NativeIngressGate()

            assertInvalid(gate, raw)
            assertDrained(gate)
        }
    }

    func testFoundationCyclesAreRejectedButSharedAcyclicValuesAreAccepted() throws {
        let gate = NativeIngressGate()
        let array = NSMutableArray()
        array.add(array)
        defer { array.removeAllObjects() }
        assertInvalid(gate, dapp(object: ["cycle": array]))
        assertDrained(gate)

        let dictionary = NSMutableDictionary()
        dictionary.setObject(dictionary, forKey: "cycle" as NSString)
        defer { dictionary.removeAllObjects() }
        assertInvalid(gate, dapp(object: dictionary))
        assertDrained(gate)

        let shared = NSArray(object: "shared")
        let admitted = try gate.admit(dapp(object: ["first": shared, "second": shared]), profileIdentifier: nil)
        admitted.finish()
        assertDrained(gate)
    }

    func testRPCBodyHasItsOwnFourMiBBudgetAndPreservesTheOriginalPayload() throws {
        let maximum = 4_194_304
        let prefix = #"{"jsonrpc":"2.0","id":1,"method":"vendor_read","params":[""#
        let suffix = #""]}"#
        let body = prefix + String(repeating: "a", count: maximum - prefix.utf8.count - suffix.utf8.count) + suffix
        let profile = UUID()
        let gate = NativeIngressGate()
        let admitted = try gate.admit(rpc(body: body), profileIdentifier: profile)

        XCTAssertEqual(admitted.message["body"] as? String, body)
        XCTAssertEqual(admitted.message["chainId"] as? String, "0x1")
        XCTAssertNil(admitted.message[WireProtocol.nativeContextKey])
        XCTAssertEqual(admitted.context.profileIdentifier, profile)
        XCTAssertEqual(gate.statistics.inspecting, 1)
        XCTAssertGreaterThan(gate.statistics.retainedBytes, maximum)
        admitted.finish()
        assertDrained(gate)

        assertRejected(gate, rpc(body: body + " "), reason: .requestTooLarge)
        assertDrained(gate)
    }

    func testRPCMetadataNodesAndTextRemainBoundedSeparatelyFromTheBody() throws {
        var limits = NativeIngressGate.Limits()
        limits.maximumRPCMetadataNodes = 31
        let metadataBytes = contextTextBytes + ["id", "workflowVersion", "subject", "rpc", "body", "chainId", "0x1"]
            .reduce(0) { $0 + $1.utf8.count }
        limits.maximumContextTextBytes = metadataBytes
        let exact = NativeIngressGate(limits: limits)
        let admitted = try exact.admit(rpc(body: String(repeating: "a", count: 1_024)), profileIdentifier: nil)
        admitted.finish()
        assertDrained(exact)

        limits.maximumRPCMetadataNodes -= 1
        let nodeLimited = NativeIngressGate(limits: limits)
        assertRejected(nodeLimited, rpc(body: "{}"), reason: .requestTooComplex)
        assertDrained(nodeLimited)

        limits.maximumRPCMetadataNodes += 1
        limits.maximumContextTextBytes -= 1
        let textLimited = NativeIngressGate(limits: limits)
        assertRejected(textLimited, rpc(body: "{}"), reason: .requestTooLarge)
        assertDrained(textLimited)
    }

    func testOrdinaryProcessLimitIsSharedAcrossProfiles() throws {
        var limits = NativeIngressGate.Limits()
        limits.ordinaryProcessSlots = 2
        let gate = NativeIngressGate(limits: limits)
        let first = try gate.admit(normal(), profileIdentifier: UUID())
        let second = try gate.admit(normal(), profileIdentifier: UUID())
        defer { first.finish(); second.finish() }
        let full = gate.statistics

        assertRejected(gate, normal(), profileIdentifier: UUID(), reason: .busy)
        XCTAssertEqual(gate.statistics, full)
        first.finish()
        let replacement = try gate.admit(normal(), profileIdentifier: UUID())
        replacement.finish()
        second.finish()
        assertDrained(gate)
    }

    func testOrdinaryProfileAndDocumentScopeLimitsAreIndependent() throws {
        var limits = NativeIngressGate.Limits()
        limits.ordinaryProcessSlots = 8
        limits.ordinaryProfileSlots = 2
        limits.ordinaryScopeSlots = 1
        let gate = NativeIngressGate(limits: limits)
        let profile = UUID()
        let first = try gate.admit(normal(tab: 1), profileIdentifier: profile)
        defer { first.finish() }
        assertRejected(gate, normal(id: 2, tab: 1), profileIdentifier: profile, reason: .busy, id: 2)
        let second = try gate.admit(normal(tab: 2), profileIdentifier: profile)
        defer { second.finish() }
        assertRejected(gate, normal(tab: 3), profileIdentifier: profile, reason: .busy)
        let otherProfile = try gate.admit(normal(tab: 1), profileIdentifier: UUID())
        XCTAssertEqual(gate.statistics.ordinary, 3)
        otherProfile.finish()
        first.finish()
        second.finish()
        assertDrained(gate)
    }

    func testOrdinaryRetainedByteBudgetAcceptsExactlyOneEnvelopeAndReleasesIt() throws {
        let charge = payloadTextBytes + contextTextBytes + 29 * 64
        var limits = NativeIngressGate.Limits()
        limits.ordinaryRetainedBytes = charge
        let gate = NativeIngressGate(limits: limits)
        let first = try gate.admit(normal(), profileIdentifier: nil)
        XCTAssertEqual(gate.statistics.retainedBytes, charge)
        assertRejected(gate, normal(tab: 2), reason: .busy)
        XCTAssertEqual(gate.statistics.retainedBytes, charge)
        first.finish()
        let replacement = try gate.admit(normal(tab: 2), profileIdentifier: nil)
        replacement.finish()
        assertDrained(gate)

        limits.ordinaryRetainedBytes = charge - 1
        let limited = NativeIngressGate(limits: limits)
        assertRejected(limited, normal(), reason: .busy)
        assertDrained(limited)
    }

    func testReservedRejectionRevocationAndCompletionRemainAvailableWhenOrdinaryIsFull() throws {
        var limits = NativeIngressGate.Limits()
        limits.ordinaryProcessSlots = 1
        limits.ordinaryRetainedBytes = payloadTextBytes + contextTextBytes + 29 * 64
        let gate = NativeIngressGate(limits: limits)
        let ordinary = try gate.admit(normal(), profileIdentifier: nil)
        let rejection = try gate.admit(reject(), profileIdentifier: nil)
        let revocation = try gate.admit(disconnect(), profileIdentifier: nil)
        let completion = try gate.admit(poll(maintenance: "none"), profileIdentifier: nil)
        defer { ordinary.finish(); rejection.finish(); revocation.finish(); completion.finish() }

        XCTAssertEqual(gate.statistics.ordinary, 1)
        XCTAssertEqual(gate.statistics.rejection, 1)
        XCTAssertEqual(gate.statistics.revocation, 1)
        XCTAssertEqual(gate.statistics.completion, 1)
        let full = gate.statistics
        assertRejected(gate, reject(id: 2), reason: .busy, id: 2)
        assertRejected(gate, disconnect(id: 2), reason: .busy, id: 2)
        assertRejected(gate, normal(tab: 2), reason: .busy)
        XCTAssertEqual(gate.statistics, full)
    }

    func testMaintenancePollingAndApprovalWorkCannotUseCompletionCapacity() throws {
        var limits = NativeIngressGate.Limits()
        limits.ordinaryProcessSlots = 1
        let gate = NativeIngressGate(limits: limits)
        let ordinary = try gate.admit(normal(), profileIdentifier: nil)
        defer { ordinary.finish() }

        for maintenance in ["quiet", "interactive"] {
            assertRejected(gate, poll(maintenance: maintenance), reason: .busy)
        }
        assertRejected(gate, command("getApprovalState", fields: ["requestToken": Self.requestToken], source: "popup"), reason: .busy)
        assertRejected(gate, command("approveRequest", fields: [
            "requestToken": Self.requestToken, "reviewToken": Self.requestToken, "payload": [:],
        ], source: "popup"), reason: .busy)

        let completion = try gate.admit(poll(maintenance: "none"), profileIdentifier: nil)
        XCTAssertEqual(gate.statistics.completion, 1)
        completion.finish()
        XCTAssertEqual(gate.statistics.ordinary, 1)
    }

    func testCompletionCommandsUseBoundedProcessProfileAndScopeCapacity() throws {
        var limits = NativeIngressGate.Limits()
        limits.completionProcessSlots = 3
        limits.completionProfileSlots = 2
        limits.completionScopeSlots = 1
        let gate = NativeIngressGate(limits: limits)
        let profile = UUID()
        let first = try gate.admit(poll(maintenance: "none"), profileIdentifier: profile)
        defer { first.finish() }
        assertRejected(gate, command("acknowledgeResponse", fields: responseIdentity), profileIdentifier: profile, reason: .busy)
        let popup = try gate.admit(command("getPendingRequests", source: "popup"), profileIdentifier: profile)
        defer { popup.finish() }
        assertRejected(gate, command("getRecoveryRequests", source: "worker"), profileIdentifier: profile, reason: .busy)
        let worker = try gate.admit(command("getRecoveryRequests", source: "worker"), profileIdentifier: UUID())
        defer { worker.finish() }
        assertRejected(gate, command("getPendingRequests", source: "popup"), profileIdentifier: UUID(), reason: .busy)
        XCTAssertEqual(gate.statistics.completion, 3)
    }

    func testReservedRetainedBytesAreBoundedIndependentlyOfOrdinaryBytes() throws {
        var limits = NativeIngressGate.Limits()
        limits.reservedRetainedBytes = 0
        let gate = NativeIngressGate(limits: limits)
        assertRejected(gate, reject(), reason: .busy)
        assertRejected(gate, disconnect(), reason: .busy)
        assertRejected(gate, poll(maintenance: "none"), reason: .busy)
        assertDrained(gate)
        let ordinary = try gate.admit(normal(), profileIdentifier: nil)
        ordinary.finish()
        assertDrained(gate)
    }

    func testScopeAndProfileInventoriesAreBoundedAndRemovedWhenLeasesFinish() throws {
        var limits = NativeIngressGate.Limits()
        limits.ordinaryProcessSlots = 8
        limits.ordinaryProfileSlots = 8
        limits.maximumScopes = 2
        limits.maximumProfiles = 1
        let gate = NativeIngressGate(limits: limits)
        let first = try gate.admit(normal(tab: 1), profileIdentifier: nil)
        let second = try gate.admit(normal(tab: 2), profileIdentifier: nil)
        defer { first.finish(); second.finish() }
        assertRejected(gate, normal(tab: 3), reason: .busy)
        assertRejected(gate, normal(tab: 1), profileIdentifier: UUID(), reason: .busy)
        XCTAssertEqual(gate.statistics.scopes, 2)
        XCTAssertEqual(gate.statistics.profiles, 1)

        second.finish()
        assertRejected(gate, normal(tab: 1), profileIdentifier: UUID(), reason: .busy)
        let replacementScope = try gate.admit(normal(tab: 3), profileIdentifier: nil)
        replacementScope.finish()
        first.finish()
        assertDrained(gate)
        let replacementProfile = try gate.admit(normal(), profileIdentifier: UUID())
        replacementProfile.finish()
        assertDrained(gate)
    }

    func testCopiedAdmissionFinishesOnceAndDeinitializationReleasesTheLastCopy() throws {
        let gate = NativeIngressGate()
        var first: NativeIngressGate.Admission? = try gate.admit(normal(), profileIdentifier: nil)
        var copy = first
        first = nil
        withExtendedLifetime(copy) { XCTAssertEqual(gate.statistics.ordinary, 1) }
        copy = nil
        assertDrained(gate)

        let finished = try gate.admit(normal(), profileIdentifier: nil)
        let finishedCopy = finished
        finished.finish()
        let replacement = try gate.admit(normal(), profileIdentifier: nil)
        let retained = gate.statistics
        finishedCopy.finish()
        finished.finish()
        XCTAssertEqual(gate.statistics, retained)
        replacement.finish()
        assertDrained(gate)
    }

    func testCancellationRetainsAdmissionUntilUncooperativeWorkActuallyExits() async throws {
        var limits = NativeIngressGate.Limits()
        limits.ordinaryProcessSlots = 1
        let gate = NativeIngressGate(limits: limits)
        let entered = TestGate<Void>()
        let exit = TestGate<Void>()
        defer { exit.resolve(()) }
        let task = Task {
            let admission = try gate.admit(normal(), profileIdentifier: nil)
            defer { admission.finish() }
            entered.resolve(())
            await exit.wait()
            XCTAssertTrue(Task.isCancelled)
        }
        await entered.wait()
        let retained = gate.statistics
        task.cancel()

        assertRejected(gate, normal(tab: 2), reason: .busy)
        XCTAssertEqual(gate.statistics, retained)
        exit.resolve(())
        try await task.value
        assertDrained(gate)
    }

    func testTimeoutCancellationDoesNotReleaseAnExecutingAdmissionEarly() async throws {
        var limits = NativeIngressGate.Limits()
        limits.ordinaryProcessSlots = 1
        let gate = NativeIngressGate(limits: limits)
        let entered = TestGate<Void>()
        let exit = TestGate<Void>()
        let timeout = TestGate<Void>()
        let timedOut = TestGate<Void>()
        defer { exit.resolve(()); timeout.resolve(()) }
        let task = Task {
            let admission = try gate.admit(normal(), profileIdentifier: nil)
            defer { admission.finish() }
            entered.resolve(())
            await exit.wait()
        }
        let timer = Task {
            await timeout.wait()
            task.cancel()
            timedOut.resolve(())
        }
        await entered.wait()
        timeout.resolve(())
        await timedOut.wait()

        XCTAssertEqual(gate.statistics.ordinary, 1)
        assertRejected(gate, normal(tab: 2), reason: .busy)
        exit.resolve(())
        try await task.value
        await timer.value
        assertDrained(gate)
    }

    func testRPCAdmissionHandoffReleasesInspectionAndBytesExactlyOnce() throws {
        var limits = NativeIngressGate.Limits()
        limits.ordinaryInspectionSlots = 1
        let gate = NativeIngressGate(limits: limits)
        let rpcAdmission = try gate.admit(rpc(body: "{}"), profileIdentifier: nil)
        let rpcCopy = rpcAdmission
        defer { rpcAdmission.finish() }
        XCTAssertEqual(gate.statistics.inspecting, 1)
        assertRejected(gate, normal(), reason: .busy)
        let reserved = try gate.admit(reject(), profileIdentifier: nil)
        reserved.finish()

        rpcAdmission.rpcAdmissionDecided()
        assertDrained(gate)
        let ordinary = try gate.admit(normal(), profileIdentifier: nil)
        let retained = gate.statistics
        rpcCopy.rpcAdmissionDecided()
        rpcAdmission.finish()
        rpcCopy.finish()
        XCTAssertEqual(gate.statistics, retained)
        ordinary.rpcAdmissionDecided()
        XCTAssertEqual(gate.statistics, retained)
        ordinary.finish()
        assertDrained(gate)
    }

    func testUnauthorizedReservedSubjectsAndProfileOverridesNeverProduceAdmissions() {
        let gate = NativeIngressGate()
        for raw in [
            command("rejectRequest", fields: ["requestToken": Self.requestToken]),
            command("getRecoveryRequests"),
            command("disconnect", fields: disconnectFields, source: "worker"),
            command("rpc", fields: ["body": "{}", "chainId": "0x1"], source: "popup"),
            normal().merging(["profileIdentifier": UUID().uuidString]) { _, new in new },
            command("getPendingRequests", source: "worker"),
        ] {
            assertInvalid(gate, raw)
            assertDrained(gate)
        }
    }

    func testPrivateBrowsingAndOSProfileRemainBoundToDetachedContext() throws {
        let gate = NativeIngressGate()
        let profile = UUID()
        let raw = NSMutableDictionary(dictionary: normal())
        let transport = NSMutableDictionary(dictionary: context(privateBrowsing: true))
        raw[WireProtocol.nativeContextKey] = transport
        let admitted = try gate.admit(raw, profileIdentifier: profile)
        defer { admitted.finish() }
        transport["privateBrowsing"] = false
        raw["configurationKey"] = "https://other.example"

        XCTAssertTrue(admitted.context.privateBrowsing)
        XCTAssertEqual(admitted.context.profileIdentifier, profile)
        XCTAssertEqual(admitted.message["configurationKey"] as? String, Self.origin)
        guard case .site(let site, let document) = admitted.context.source else {
            return XCTFail("Expected the original site context")
        }
        XCTAssertEqual(site.configurationKey, Self.origin)
        XCTAssertEqual(document.documentSession, Self.documentSession)
    }

    func testOverloadRepliesRequireSafeCorrelationAndDoNotAdvertiseDispatch() {
        var limits = NativeIngressGate.Limits()
        limits.ordinaryInspectionSlots = 0
        let gate = NativeIngressGate(limits: limits)
        let busy = assertRejected(gate, normal(id: 37), reason: .busy, id: 37)
        XCTAssertEqual(busy?.response?.json["nativeAdmissionRejected"] as? Bool, true)
        XCTAssertEqual(busy?.response?.json["code"] as? Int, -32_005)
        XCTAssertEqual(busy?.response?.json["dispatched"] as? Bool, false)
        XCTAssertEqual(busy?.response?.json["retryAfterMilliseconds"] as? Int, 500)
        assertRejected(gate, normal(id: -1), reason: .busy, id: -1)

        for invalidID: Any in [true, 1.5, -9_007_199_254_740_992, 9_007_199_254_740_992, "1"] {
            var invalid = normal()
            invalid["id"] = invalidID
            assertInvalid(gate, invalid)
        }
        for version: Any in [true, WireProtocol.workflowVersion + 1, "\(WireProtocol.workflowVersion)"] {
            var invalid = normal()
            invalid["workflowVersion"] = version
            assertInvalid(gate, invalid)
        }
        assertDrained(gate)
    }

    private var payloadTextBytes: Int {
        ["id", "workflowVersion", "subject", "getLatestConfiguration", "configurationKey", Self.origin]
            .reduce(0) { $0 + $1.utf8.count }
    }

    private var contextTextBytes: Int {
        [WireProtocol.nativeContextKey, "source", "site", "privateBrowsing", "site", "host", Self.host,
         "configurationKey", Self.origin, "document", "tabId", "frameId", "documentSession", Self.documentSession]
            .reduce(0) { $0 + $1.utf8.count }
    }

    private var responseIdentity: [String: Any] {
        ["configurationKey": Self.origin, "requestToken": Self.requestToken]
    }

    private var disconnectFields: [String: Any] {
        ["configurationKey": Self.origin, "provider": "ethereum", "attempt": String(repeating: "b", count: 32),
         "authority": ["context": String(repeating: "a", count: 64), "revisions": ["ethereum": 0, "solana": 0]]]
    }

    private func context(source: String = "site", tab: Int = 1, documentID: String? = nil,
                         privateBrowsing: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["source": source, "privateBrowsing": privateBrowsing]
        if source == "site" {
            result["site"] = ["host": Self.host, "configurationKey": Self.origin]
            var document: [String: Any] = ["tabId": tab, "frameId": 0, "documentSession": Self.documentSession]
            document["documentId"] = documentID
            result["document"] = document
        }
        return result
    }

    private func command(_ subject: String, id: Int = 1, fields: [String: Any] = [:], source: String = "site",
                         tab: Int = 1, documentID: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["id": id, "workflowVersion": WireProtocol.workflowVersion, "subject": subject,
                                   WireProtocol.nativeContextKey: context(source: source, tab: tab, documentID: documentID)]
        result.merge(fields) { _, value in value }
        return result
    }

    private func normal(id: Int = 1, tab: Int = 1, documentID: String? = nil) -> [String: Any] {
        command("getLatestConfiguration", id: id, fields: ["configurationKey": Self.origin], tab: tab, documentID: documentID)
    }

    private func rpc(body: String) -> [String: Any] {
        command("rpc", fields: ["chainId": "0x1", "body": body])
    }

    private func reject(id: Int = 1) -> [String: Any] {
        command("rejectRequest", id: id, fields: ["requestToken": Self.requestToken], source: "popup")
    }

    private func disconnect(id: Int = 1) -> [String: Any] {
        command("disconnect", id: id, fields: disconnectFields)
    }

    private func poll(maintenance: String) -> [String: Any] {
        command("pollResponse", fields: responseIdentity.merging(["maintenance": maintenance]) { _, value in value })
    }

    private func dapp(object: Any) -> [String: Any] {
        ["id": 1, "workflowVersion": WireProtocol.workflowVersion, "host": Self.host, "configurationKey": Self.origin,
         "enqueueAttempt": String(repeating: "b", count: 32), "admissionDeadline": 2_000_000_000_000,
         "authority": ["context": String(repeating: "a", count: 64), "revisions": ["ethereum": 0, "solana": 0]],
         "provider": "ethereum", "name": "requestAccounts", "body": ["address": "", "object": object],
         WireProtocol.nativeContextKey: context()]
    }

    private func nestedArrays(_ count: Int) -> Any {
        var value: Any = NSNull()
        for _ in 0..<count { value = NSArray(object: value) }
        return value
    }

    @discardableResult
    private func assertRejected(_ gate: NativeIngressGate, _ raw: Any, profileIdentifier: UUID? = nil,
                                reason: NativeIngressGate.RejectionReason, id: Int = 1,
                                file: StaticString = #filePath, line: UInt = #line) -> NativeIngressGate.Rejection? {
        do {
            let admitted = try gate.admit(raw, profileIdentifier: profileIdentifier)
            admitted.finish()
            XCTFail("Expected a bounded admission rejection", file: file, line: line)
        } catch NativeIngressGate.Failure.rejected(let rejection) {
            XCTAssertEqual(rejection.reason, reason, file: file, line: line)
            XCTAssertEqual(rejection.id, id, file: file, line: line)
            XCTAssertNotNil(rejection.response, file: file, line: line)
            XCTAssertEqual(rejection.response?.json["reason"] as? String, reason.rawValue, file: file, line: line)
            return rejection
        } catch {
            XCTFail("Unexpected rejection: \(error)", file: file, line: line)
        }
        return nil
    }

    private func assertInvalid(_ gate: NativeIngressGate, _ raw: Any,
                               file: StaticString = #filePath, line: UInt = #line) {
        do {
            let admitted = try gate.admit(raw, profileIdentifier: nil)
            admitted.finish()
            XCTFail("Expected an invalid native message", file: file, line: line)
        } catch NativeIngressGate.Failure.invalidMessage {
        } catch {
            XCTFail("Unexpected rejection: \(error)", file: file, line: line)
        }
    }

    private func assertDrained(_ gate: NativeIngressGate, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(gate.statistics, NativeIngressGate.Statistics(
            inspecting: 0, retainedBytes: 0, ordinary: 0, rejection: 0, revocation: 0, completion: 0, scopes: 0, profiles: 0
        ), file: file, line: line)
    }
}

private final class ReadCountingArray: NSArray, @unchecked Sendable {
    private let reportedCount: Int
    private let reads = Mutex(0)

    init(reportedCount: Int) {
        self.reportedCount = reportedCount
        super.init()
    }

    override init() {
        reportedCount = 0
        super.init()
    }

    override init(objects: UnsafePointer<AnyObject>?, count: Int) {
        reportedCount = count
        super.init()
    }

    required convenience init?(coder: NSCoder) { self.init(reportedCount: 0) }

    override var count: Int { reportedCount }
    var elementReads: Int { reads.withLock { $0 } }

    override func object(at index: Int) -> Any {
        reads.withLock { $0 += 1 }
        return NSNull()
    }
}
