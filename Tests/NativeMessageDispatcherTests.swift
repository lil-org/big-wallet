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
            let opened = try await fixture.dispatch(open, privateBrowsing: true)
            XCTAssertEqual(opened["opened"] as? Bool, true)
            await assertFailure(.unsupportedOperation) { try await fixture.dispatch(open, policy: .popup) }
            let popup = fixture.command("getPendingRequests")
            await assertFailure(.unsupportedOperation) { try await fixture.dispatch(popup) }
            _ = try await fixture.dispatch(popup, policy: .popup)
            _ = try await fixture.dispatch(popup, policy: .popup, privateBrowsing: true)
            XCTAssertEqual(fixture.calls.value, ["open", "popup", "privatePopup"])
            for message in [fixture.command("getRecoveryRequests"), fixture.command("getLatestConfiguration", fields: [
                "configurationKey": fixture.origin,
            ])] {
                await assertFailure(.unsupportedOperation) { try await fixture.dispatch(message, privateBrowsing: true) }
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

        init(root: URL) {
            bridge = ExtensionBridge(store: ExtensionRequestFileStore(rootURL: root, directoryBoundary: root))
        }

        func command(_ subject: String, fields: [String: Any] = [:]) -> [String: Any] {
            fields.merging(["id": 1, "subject": subject, "workflowVersion": ExtensionBridge.workflowVersion]) { _, new in new }
        }

        func connectionMessage() async throws -> [String: Any] {
            guard case .snapshot(let authority) = await bridge.configurationSnapshot(configurationKey: origin, profileIdentifier: nil) else {
                throw CocoaError(.fileReadUnknown)
            }
            return ["id": 1, "name": "requestAccounts", "provider": "ethereum", "host": "wallet.example",
                "configurationKey": origin, "authority": authority.version.json,
                "enqueueAttempt": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                "admissionDeadline": Int(Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000),
                "workflowVersion": ExtensionBridge.workflowVersion, "body": ["address": "", "chainId": "0x1"]]
        }

        func dispatch(
            _ message: [String: Any], policy: NativeMessageDispatcher.ApprovalPolicy = .native,
            privateBrowsing: Bool = false, profile: UUID? = nil
        ) async throws -> [String: Any] {
            let calls = calls
            let bridge = bridge
            let popup: @Sendable () -> PopupResponse = {
                .queue(.init(requests: [], completedResponses: [], strings: Strings.popup, layoutDirection: .ltr))
            }
            let dispatcher = NativeMessageDispatcher(policy: policy, dependencies: .init(
                bridge: bridge,
                materialize: { _ in calls.withValue { $0.append("materialize") }; return .approvalRequired },
                reconcile: { _, _ in calls.withValue { $0.append("reconcile") }; return .opened },
                pollResponse: { handle, origin, _ in
                    await bridge.prepareResponseDelivery(id: handle.id, configurationKey: origin,
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
            let object = try XCTUnwrap(WireProtocol.JSONObject(message))
            return try await dispatcher.dispatch(message: object, profileIdentifier: profile, privateBrowsing: privateBrowsing).json
        }
    }
}
