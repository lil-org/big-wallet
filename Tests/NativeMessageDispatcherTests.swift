import Foundation
import XCTest
@testable import Big_Wallet

@MainActor
final class NativeMessageDispatcherTests: XCTestCase {
    func testMalformedCommandsNeverReachDependencies() async throws {
        try await withFixture { fixture in
            for message: [String: Any] in [
                ["id": 1, "subject": "executeNativeApproval", "workflowVersion": ExtensionBridge.workflowVersion],
                ["id": 1, "subject": "openApp", "workflowVersion": ExtensionBridge.workflowVersion + 1],
                ["id": 1, "subject": "openApp", "workflowVersion": ExtensionBridge.workflowVersion, "unexpected": true],
            ] {
                await assertFailure(.invalidMessage) { try await fixture.dispatch(message) }
            }
            XCTAssertTrue(fixture.calls.value.isEmpty)
        }
    }

    func testPlatformPolicyAndPrivateBrowsingPreserveRouting() async throws {
        try await withFixture { fixture in
            let open = fixture.command("openApp")
            let opened = try await fixture.dispatch(open, source: "worker", privateBrowsing: true)
            XCTAssertEqual(opened["opened"] as? Bool, true)
            await assertFailure(.unsupportedOperation) { try await fixture.dispatch(open, policy: .popup, source: "worker") }
            let popup = fixture.command("getPendingRequests")
            await assertFailure(.unsupportedOperation) { try await fixture.dispatch(popup, source: "popup") }
            _ = try await fixture.dispatch(popup, policy: .popup, source: "popup")
            _ = try await fixture.dispatch(popup, policy: .popup, source: "popup", privateBrowsing: true)
            XCTAssertEqual(fixture.calls.value, ["open", "popup", "privatePopup"])
            for message in [fixture.command("getRecoveryRequests"), fixture.command("getLatestConfiguration", fields: [
                "configurationKey": fixture.origin,
            ])] {
                await assertFailure(.unsupportedOperation) { try await fixture.dispatch(message, source: "worker", privateBrowsing: true) }
            }
            XCTAssertEqual(fixture.calls.value, ["open", "popup", "privatePopup"])
        }
    }

    func testNativeAdmissionAndReplayKeepStoredIdentity() async throws {
        try await withFixture { fixture in
            let message = try await fixture.connectionMessage()
            let first = try await fixture.dispatch(message)
            let replay = try await fixture.dispatch(message)
            XCTAssertEqual(first["admissionKind"] as? String, "new")
            XCTAssertEqual(replay["admissionKind"] as? String, "replay")
            XCTAssertEqual(first["requestToken"] as? String, replay["requestToken"] as? String)
            XCTAssertEqual(first["approvalRequired"] as? Bool, true)
            XCTAssertEqual(fixture.calls.value, ["materialize", "reconcile", "materialize", "reconcile"])
            guard case .available(let requests) = await fixture.bridge.listRecoveryRequests(profileIdentifier: nil) else {
                return XCTFail("Expected stored request")
            }
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testPopupAdmissionDoesNotLaunchTheNativeHelper() async throws {
        try await withFixture { fixture in
            let message = try await fixture.connectionMessage()
            let response = try await fixture.dispatch(message, policy: .popup)
            XCTAssertEqual(response["approvalRequired"] as? Bool, true)
            XCTAssertEqual(fixture.calls.value, ["materialize"])
        }
    }

    func testPrivateDappRequestIsRejectedBeforeAdmission() async throws {
        try await withFixture { fixture in
            let message = try await fixture.connectionMessage()
            let result = try await fixture.dispatch(message, privateBrowsing: true)
            XCTAssertEqual(result["kind"] as? String, "error")
            XCTAssertTrue(fixture.calls.value.isEmpty)
            guard case .available(let requests) = await fixture.bridge.listRecoveryRequests(profileIdentifier: nil) else {
                return XCTFail("Expected empty store")
            }
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testShowApprovalRequiresTheStoredOriginAndProfile() async throws {
        try await withFixture { fixture in
            let admitted = try await fixture.dispatch(try await fixture.connectionMessage())
            let token = try XCTUnwrap(admitted["requestToken"] as? String)
            fixture.calls.value = []
            let wrongOrigin = fixture.command("showApproval", fields: [
                "configurationKey": "https://other.example", "requestToken": token,
            ])
            await assertFailure(.invalidMessage) { try await fixture.dispatch(wrongOrigin) }
            let correct = fixture.command("showApproval", fields: [
                "configurationKey": fixture.origin, "requestToken": token,
            ])
            await assertFailure(.invalidMessage) { try await fixture.dispatch(correct, profile: UUID()) }
            XCTAssertTrue(fixture.calls.value.isEmpty)
            let opened = try await fixture.dispatch(correct)
            XCTAssertEqual(opened["opened"] as? Bool, true)
            XCTAssertEqual(fixture.calls.value, ["reconcile"])
        }
    }

    func testTerminalDeliveryAndAcknowledgementUseTheSameStoredResponse() async throws {
        try await withFixture { fixture in
            let admitted = try await fixture.dispatch(try await fixture.connectionMessage())
            let token = try XCTUnwrap(ExtensionBridge.RequestToken(rawValue: admitted["requestToken"] as? String ?? ""))
            let handle = ExtensionBridge.Handle(id: 1, token: token, profileIdentifier: nil)
            let completed = await fixture.bridge.completeImmediate(handle: handle, resolution: .failure(.userRejected))
            XCTAssertEqual(completed, .persisted)
            let identity: [String: Any] = ["configurationKey": fixture.origin, "requestToken": token.rawValue]
            let poll = fixture.command("pollResponse", fields: identity.merging(["maintenance": "none"]) { _, new in new })
            let first = try await fixture.dispatch(poll)
            XCTAssertNotNil(first["response"])
            let acknowledgement = try await fixture.dispatch(fixture.command("acknowledgeResponse", fields: identity))
            XCTAssertEqual(acknowledgement["acknowledged"] as? Bool, true)
            let replay = try await fixture.dispatch(poll)
            XCTAssertEqual(try canonical(first["response"]), try canonical(replay["response"]))
        }
    }

    func testRPCResponseIsProjectedAndCorrelatedWithoutLeakingUpstreamFields() async throws {
        try await withFixture { fixture in
            let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\",\"params\":[]}"
            let result = try await fixture.dispatch(fixture.command("rpc", fields: ["chainId": "0x1", "body": body]))
            XCTAssertEqual(result["result"] as? String, "0x1")
            XCTAssertNil(result["privateUpstreamField"])
            XCTAssertEqual(fixture.calls.value, ["rpc"])
        }
    }

    func testSiteIdentityMismatchesNeverReachDependencies() async throws {
        try await withFixture { fixture in
            let origin = "https://other.example"
            let token = "00000000-0000-4000-8000-000000000001"
            let identity: [String: Any] = ["configurationKey": origin, "requestToken": token]
            var dapp = try await fixture.connectionMessage()
            dapp["host"] = "other.example"
            dapp["configurationKey"] = origin
            let authority = try XCTUnwrap(dapp["authority"])
            let messages = [
                dapp,
                fixture.command("getLatestConfiguration", fields: ["configurationKey": origin]),
                fixture.command("disconnect", fields: [
                    "configurationKey": origin, "provider": "ethereum", "authority": authority,
                    "attempt": String(repeating: "a", count: 32),
                ]),
                fixture.command("pollResponse", fields: identity.merging(["maintenance": "interactive"]) { _, new in new }),
                fixture.command("acknowledgeResponse", fields: identity),
                fixture.command("showApproval", fields: identity),
            ]
            for message in messages {
                await assertFailure(.invalidMessage) { try await fixture.dispatch(message) }
            }
            var wrongHost = try await fixture.connectionMessage()
            wrongHost["host"] = "other.example"
            await assertFailure(.invalidMessage) { try await fixture.dispatch(wrongHost) }
            XCTAssertTrue(fixture.calls.value.isEmpty)
            XCTAssertTrue(fixture.bridgeCalls.value.isEmpty)
        }
    }

    func testOrdinaryDappRequestsAndRPCRequireSiteContext() async throws {
        try await withFixture { fixture in
            let ethereum = try await fixture.connectionMessage()
            var solana = ethereum
            solana["provider"] = "solana"
            solana["name"] = "connect"
            solana["body"] = ["publicKey": "", "object": ["params": [String: Any]()]]
            let rpc = fixture.command("rpc", fields: [
                "chainId": "0x1", "body": "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\",\"params\":[]}",
            ])
            for message in [ethereum, solana] {
                XCTAssertNotNil(WireProtocol.object(.dappRequest, value: message))
                XCTAssertNotNil(SafariRequest(json: message))
            }
            for source in ["popup", "worker"] {
                for message in [ethereum, solana, rpc] {
                    await assertFailure(.invalidMessage) { try await fixture.dispatch(message, source: source) }
                }
            }
            XCTAssertTrue(fixture.calls.value.isEmpty)
            XCTAssertTrue(fixture.bridgeCalls.value.isEmpty)
        }
    }

    func testSourceRolesRejectUnrelatedOperationsBeforeSideEffects() async throws {
        try await withFixture { fixture in
            let connection = try await fixture.connectionMessage()
            let disconnect = fixture.command("disconnect", fields: [
                "configurationKey": fixture.origin, "provider": "ethereum",
                "authority": try XCTUnwrap(connection["authority"]), "attempt": String(repeating: "a", count: 32),
            ])
            let show = fixture.command("showApproval", fields: [
                "configurationKey": fixture.origin, "requestToken": "00000000-0000-4000-8000-000000000001",
            ])
            for (source, message) in [
                ("site", fixture.command("getRecoveryRequests")),
                ("popup", fixture.command("getRecoveryRequests")),
                ("site", fixture.command("getPendingRequests")),
                ("worker", fixture.command("getPendingRequests")),
                ("site", fixture.command("openApp")),
                ("popup", fixture.command("openApp")),
                ("worker", disconnect), ("popup", disconnect), ("popup", show),
            ] {
                await assertFailure(.invalidMessage) { try await fixture.dispatch(message, source: source) }
            }
            XCTAssertTrue(fixture.calls.value.isEmpty)
            XCTAssertTrue(fixture.bridgeCalls.value.isEmpty)
        }
    }

    func testRecoveryAndPopupCompletionKeepStoredOriginsAndOSProfiles() async throws {
        try await withFixture { fixture in
            let profile = UUID()
            let queuedOrigin = "https://queued.example"
            let message = try await fixture.connectionMessage(origin: queuedOrigin, profile: profile)
            let admitted = try await fixture.dispatch(message, profile: profile, siteOrigin: queuedOrigin)
            let token = try XCTUnwrap(ExtensionBridge.RequestToken(rawValue: admitted["requestToken"] as? String ?? ""))
            let handle = ExtensionBridge.Handle(id: 1, token: token, profileIdentifier: profile)
            let completion = await fixture.bridge.completeImmediate(handle: handle, resolution: .failure(.userRejected))
            XCTAssertEqual(completion, .persisted)
            let identity: [String: Any] = ["configurationKey": queuedOrigin, "requestToken": token.rawValue]
            for source in ["worker", "popup"] {
                let configuration = try await fixture.dispatch(fixture.command("getLatestConfiguration", fields: [
                    "configurationKey": queuedOrigin,
                ]), source: source, profile: profile)
                XCTAssertNotNil(configuration["state"])
                let poll = fixture.command("pollResponse", fields: identity.merging(["maintenance": "quiet"]) { _, new in new })
                let missing = try await fixture.dispatch(poll, source: source)
                XCTAssertEqual(missing["missing"] as? Bool, true)
                let completed = try await fixture.dispatch(poll, source: source, profile: profile)
                XCTAssertNotNil(completed["response"])
                let acknowledgement = try await fixture.dispatch(
                    fixture.command("acknowledgeResponse", fields: identity), source: source, profile: profile
                )
                XCTAssertEqual(acknowledgement["acknowledged"] as? Bool, true)
            }
            let recovery = try await fixture.dispatch(fixture.command("getRecoveryRequests"), source: "worker", profile: profile)
            XCTAssertNotNil(recovery["requests"])
        }
    }

    func testWorkerToolbarManualSwitchStillAdmitsAndFocuses() async throws {
        try await withFixture { fixture in
            var message = try await fixture.connectionMessage()
            message["provider"] = "unknown"
            message["name"] = "switchAccount"
            message["body"] = [String: Any]()
            let admitted = try await fixture.dispatch(message, source: "worker")
            let token = try XCTUnwrap(admitted["requestToken"] as? String)
            let focused = try await fixture.dispatch(fixture.command("showApproval", fields: [
                "configurationKey": fixture.origin, "requestToken": token,
            ]), source: "worker")
            XCTAssertEqual(focused["opened"] as? Bool, true)
            XCTAssertEqual(fixture.calls.value, ["materialize", "reconcile", "reconcile"])
        }
    }

    func testPrivateContextsCannotPerformWalletWork() async throws {
        try await withFixture { fixture in
            let connection = try await fixture.connectionMessage()
            let identity: [String: Any] = [
                "configurationKey": fixture.origin, "requestToken": "00000000-0000-4000-8000-000000000001",
            ]
            for source in ["site", "popup", "worker"] {
                for message in [
                    fixture.command("getLatestConfiguration", fields: ["configurationKey": fixture.origin]),
                    fixture.command("pollResponse", fields: identity.merging(["maintenance": "quiet"]) { _, new in new }),
                    fixture.command("acknowledgeResponse", fields: identity),
                ] {
                    await assertFailure(.unsupportedOperation) {
                        try await fixture.dispatch(message, source: source, privateBrowsing: true)
                    }
                }
            }
            for message in [
                fixture.command("rpc", fields: ["chainId": "0x1", "body": "{}"]),
                fixture.command("disconnect", fields: [
                    "configurationKey": fixture.origin, "provider": "ethereum",
                    "authority": try XCTUnwrap(connection["authority"]), "attempt": String(repeating: "a", count: 32),
                ]),
                fixture.command("showApproval", fields: identity),
            ] {
                await assertFailure(.unsupportedOperation) { try await fixture.dispatch(message, privateBrowsing: true) }
            }
            await assertFailure(.unsupportedOperation) {
                try await fixture.dispatch(fixture.command("getRecoveryRequests"), source: "worker", privateBrowsing: true)
            }
            XCTAssertTrue(fixture.calls.value.isEmpty)
            XCTAssertTrue(fixture.bridgeCalls.value.isEmpty)
        }
    }

    func testWirePayloadCannotSelectTheNativeProfile() async throws {
        try await withFixture { fixture in
            var message = fixture.command("getLatestConfiguration", fields: ["configurationKey": fixture.origin])
            message["profileIdentifier"] = UUID().uuidString
            await assertFailure(.invalidMessage) { try await fixture.dispatch(message, profile: UUID()) }
            XCTAssertTrue(fixture.calls.value.isEmpty)
            XCTAssertTrue(fixture.bridgeCalls.value.isEmpty)
        }
    }

    private func assertFailure(
        _ expected: NativeMessageDispatcher.Error,
        operation: () async throws -> [String: Any]
    ) async {
        do { _ = try await operation(); XCTFail("Expected dispatcher failure") }
        catch { XCTAssertEqual(error as? NativeMessageDispatcher.Error, expected) }
    }

    private func canonical(_ value: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: XCTUnwrap(value), options: [.sortedKeys, .fragmentsAllowed])
    }

    private func withFixture(_ operation: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatcher-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(Fixture(root: root))
    }

    private final class Fixture {
        let origin = "https://wallet.example"
        let bridge: ExtensionBridge
        let calls = LockedTestValue([String]())
        let bridgeCalls = LockedTestValue([String]())

        init(root: URL) {
            bridge = ExtensionBridge(store: ExtensionRequestFileStore(rootURL: root, directoryBoundary: root))
        }

        func command(_ subject: String, fields: [String: Any] = [:]) -> [String: Any] {
            fields.merging(["id": 1, "subject": subject, "workflowVersion": ExtensionBridge.workflowVersion]) { _, new in new }
        }

        func connectionMessage(origin requestedOrigin: String? = nil, profile: UUID? = nil) async throws -> [String: Any] {
            let origin = requestedOrigin ?? self.origin
            guard case .snapshot(let authority) = await bridge.configurationSnapshot(configurationKey: origin, profileIdentifier: profile) else {
                throw CocoaError(.fileReadUnknown)
            }
            return ["id": 1, "name": "requestAccounts", "provider": "ethereum", "host": try XCTUnwrap(URL(string: origin)?.host),
                "configurationKey": origin, "authority": authority.version.json,
                "enqueueAttempt": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                "admissionDeadline": Int(Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000),
                "workflowVersion": ExtensionBridge.workflowVersion, "body": ["address": "", "chainId": "0x1"]]
        }

        func dispatch(
            _ message: [String: Any], policy: NativeMessageDispatcher.ApprovalPolicy = .native,
            source: String = "site", privateBrowsing: Bool = false, profile: UUID? = nil,
            siteOrigin: String? = nil
        ) async throws -> [String: Any] {
            let calls = calls
            let bridge = bridge
            let bridgeCalls = bridgeCalls
            let popup: @Sendable () -> PopupResponse = {
                .queue(.init(requests: [], completedResponses: [], strings: Strings.popup, layoutDirection: .ltr))
            }
            let dispatcher = NativeMessageDispatcher(policy: policy, dependencies: .init(
                bridge: TrackingBridge(bridge: bridge, calls: bridgeCalls),
                materialize: { _ in calls.withValue { $0.append("materialize") }; return .approvalRequired },
                reconcile: { _, _ in calls.withValue { $0.append("reconcile") }; return .opened },
                pollResponse: { handle, origin, _ in
                    bridgeCalls.withValue { $0.append("poll") }
                    return await bridge.prepareResponseDelivery(id: handle.id, configurationKey: origin,
                        requestToken: handle.requestToken, profileIdentifier: handle.profileIdentifier)
                },
                rpcNetwork: { chain in
                    .init(network: EthereumNetwork(chainId: chain, name: "Fixture", symbol: "ETH",
                        rpcEndpoint: .unauthenticated(URL(string: "https://rpc.example")!),
                        isTestnet: true, mightShowPrice: false, explorer: nil), source: .custom)
                },
                sendRPC: { _, _, id in
                    calls.withValue { $0.append("rpc") }
                    return WireProtocol.JSONObject(["id": id, "result": "0x1", "privateUpstreamField": "discard"])!
                },
                popup: { _, _ in calls.withValue { $0.append("popup") }; return popup() },
                privatePopup: { _ in calls.withValue { $0.append("privatePopup") }; return popup() },
                openApp: { calls.withValue { $0.append("open") }; return true },
                invalidateNetworkCache: { calls.withValue { $0.append("invalidate") } }
            ))
            var transportContext: [String: Any] = ["source": source, "privateBrowsing": privateBrowsing]
            if source == "site" {
                let origin = siteOrigin ?? self.origin
                transportContext["site"] = ["host": try XCTUnwrap(URL(string: origin)?.host), "configurationKey": origin]
                transportContext["document"] = ["tabId": 1, "frameId": 0]
            }
            var transport = message
            transport[WireProtocol.nativeContextKey] = transportContext
            let ingress = try XCTUnwrap(NativeRequestContext.extract(from: transport, profileIdentifier: profile))
            return try await dispatcher.dispatch(message: ingress.message, context: ingress.context).json
        }
    }

    private final class TrackingBridge: NativeMessageBridge {
        let bridge: ExtensionBridge
        let calls: LockedTestValue<[String]>

        init(bridge: ExtensionBridge, calls: LockedTestValue<[String]>) {
            self.bridge = bridge
            self.calls = calls
        }

        func enqueue(ingress: ExtensionBridge.Ingress, profileIdentifier: UUID?, privateBrowsing: Bool) async -> ExtensionBridge.EnqueueResult {
            calls.withValue { $0.append("enqueue") }
            return await bridge.enqueue(ingress: ingress, profileIdentifier: profileIdentifier, privateBrowsing: privateBrowsing)
        }

        func configurationSnapshot(configurationKey: String, profileIdentifier: UUID?) async -> ExtensionBridge.AuthorityReadResult {
            calls.withValue { $0.append("configuration") }
            return await bridge.configurationSnapshot(configurationKey: configurationKey, profileIdentifier: profileIdentifier)
        }

        func revoke(configurationKey: String, provider: InpageProvider, attempt: String,
                    expected: ExtensionBridge.AuthorityVersion, profileIdentifier: UUID?) async -> ExtensionBridge.AuthorityMutationResult {
            calls.withValue { $0.append("revoke") }
            return await bridge.revoke(configurationKey: configurationKey, provider: provider, attempt: attempt,
                                       expected: expected, profileIdentifier: profileIdentifier)
        }

        func listRecoveryRequests(profileIdentifier: UUID?) async -> ExtensionBridge.RecoveryRequestsResult {
            calls.withValue { $0.append("recovery") }
            return await bridge.listRecoveryRequests(profileIdentifier: profileIdentifier)
        }

        func load(handle: ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult {
            calls.withValue { $0.append("load") }
            return await bridge.load(handle: handle)
        }

        func acknowledgeResponse(handle: ExtensionBridge.Handle, configurationKey: String) async -> ExtensionBridge.StoreMutationResult {
            calls.withValue { $0.append("acknowledge") }
            return await bridge.acknowledgeResponse(handle: handle, configurationKey: configurationKey)
        }
    }
}
