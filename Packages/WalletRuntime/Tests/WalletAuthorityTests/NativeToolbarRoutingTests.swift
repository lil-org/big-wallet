import Foundation
import Synchronization
import WalletDomain
import XCTest
@testable import WalletAuthority

@MainActor
final class NativeToolbarRoutingTests: XCTestCase {
    func testOnlyWorkerManualAdmissionCarriesToolbarIntent() async throws {
        for source in ["site", "worker"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let message = try await fixture.message(manual: true)
            _ = try await fixture.dispatch(message, source: source)
            let call = try XCTUnwrap(fixture.log.values.withLock { $0.first })
            XCTAssertTrue(call.intent == .admission)
            XCTAssertEqual(call.reference.isToolbarAction, source == "worker")
        }
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try await fixture.dispatch(fixture.message(manual: false), source: "site")
        XCTAssertFalse(try XCTUnwrap(fixture.log.values.withLock { $0.first }).reference.isToolbarAction)
        do {
            _ = try await fixture.dispatch(fixture.message(manual: false, id: 2), source: "worker")
            XCTFail("Worker transport admitted a page request")
        } catch NativeMessageDispatcher.Error.invalidMessage {
        }
        XCTAssertEqual(fixture.log.values.withLock { $0.count }, 1)
    }

    func testWorkerFocusMarksOnlyStoredManualSwitches() async throws {
        for manual in [false, true] {
            for source in ["site", "worker"] {
                for completed in [false, true] {
                    let fixture = try Fixture()
                    defer { fixture.cleanup() }
                    let admitted = try await fixture.dispatch(fixture.message(manual: manual), source: "site")
                    if completed { try await fixture.complete(admitted) }
                    let focused = try await fixture.focus(admitted, source: source)
                    XCTAssertEqual(focused["opened"] as? Bool, true)
                    let call = try XCTUnwrap(fixture.log.values.withLock { $0.last })
                    XCTAssertTrue(call.intent == .focus)
                    XCTAssertEqual(call.reference.isToolbarAction, manual && source == "worker")
                }
            }
        }
    }

    func testCoalescedToolbarSwitchStillCarriesExplicitFocus() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try await fixture.dispatch(fixture.message(manual: true), source: "site")
        let coalesced = try await fixture.dispatch(fixture.message(manual: true, id: 2), source: "worker")
        XCTAssertEqual(coalesced["admissionKind"] as? String, "coalesced")
        XCTAssertEqual(coalesced["requestToken"] as? String, original["requestToken"] as? String)
        XCTAssertEqual(fixture.log.values.withLock { $0.count }, 2)

        _ = try await fixture.focus(coalesced, source: "worker")
        let calls = fixture.log.values.withLock { $0 }
        XCTAssertEqual(calls.count, 3)
        XCTAssertFalse(calls[0].reference.isToolbarAction)
        XCTAssertTrue(calls[1].reference.isToolbarAction)
        XCTAssertTrue(calls[1].intent == .admission)
        XCTAssertTrue(calls[2].reference.isToolbarAction)
        XCTAssertTrue(calls[2].intent == .focus)
        XCTAssertEqual(calls[0].reference.handle, calls[1].reference.handle)
    }

    func testCoalescedToolbarIntentSurvivesRejectionBeforeFocus() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try await fixture.dispatch(fixture.message(manual: true), source: "site")
        let coalesced = try await fixture.dispatch(fixture.message(manual: true, id: 2), source: "worker")
        XCTAssertEqual(coalesced["admissionKind"] as? String, "coalesced")
        let handle = try await fixture.complete(original)
        guard case .found(let snapshot) = await fixture.bridge.load(handle: handle),
              case .available(let snapshots) = await fixture.bridge.list(profileIdentifier: nil) else {
            return XCTFail("Completed manual request was not retained")
        }
        XCTAssertNil(snapshot.request)
        XCTAssertTrue(snapshot.isManualSwitch)
        XCTAssertEqual(snapshots[handle]?.isManualSwitch, true)

        _ = try await fixture.focus(coalesced, source: "worker")
        let calls = fixture.log.values.withLock { $0 }
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls[1].reference.isToolbarAction)
        XCTAssertTrue(calls[2].reference.isToolbarAction)
        XCTAssertEqual(calls[2].reference.handle, handle)
        guard case .found(let retained) = await fixture.bridge.load(handle: handle) else {
            return XCTFail("Toolbar focus removed the completed response")
        }
        XCTAssertEqual(retained.phase, .responded)
    }

    func testToolbarIntentSurvivesCompletionDuringMaterialization() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.completesDuringMaterialization = true
        let admitted = try await fixture.dispatch(fixture.message(manual: true), source: "worker")
        XCTAssertEqual(admitted["approvalRequired"] as? Bool, false)
        let call = try XCTUnwrap(fixture.log.values.withLock { $0.first })
        XCTAssertTrue(call.intent == .admission)
        XCTAssertTrue(call.reference.isToolbarAction)
        guard case .found(let snapshot) = await fixture.bridge.load(handle: call.reference.handle) else {
            return XCTFail("Completed manual request was not retained")
        }
        XCTAssertEqual(snapshot.phase, .responded)
        XCTAssertTrue(snapshot.isManualSwitch)
    }

    func testWirePayloadCannotSupplyToolbarIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var message = try await fixture.message(manual: true)
        message["isToolbarAction"] = true
        do {
            _ = try await fixture.dispatch(message, source: "site")
            XCTFail("Page payload supplied trusted toolbar intent")
        } catch NativeMessageDispatcher.Error.invalidMessage {
        }
        XCTAssertTrue(fixture.log.values.withLock { $0.isEmpty })
    }

    func testToolbarRouteRoundTripsOnlyTheExactNativeIdentity() throws {
        for profile in [nil, UUID()] as [UUID?] {
            let handle = RequestHandle(id: 42, token: .init(value: UUID()), profileIdentifier: profile)
            let nonce = NativeDeliveryNonce(value: UUID())
            let route = NativeAgentRoute.toolbarApproval(workflowVersion: ExtensionBridge.workflowVersion,
                handle: handle, nativeDeliveryNonce: nonce)
            XCTAssertEqual(route.url.path, "/toolbar-approval")
            XCTAssertEqual(NativeAgentRoute(url: route.url), route)
            let ordinary = NativeAgentRoute.approval(workflowVersion: ExtensionBridge.workflowVersion,
                handle: handle, nativeDeliveryNonce: nonce)
            XCTAssertEqual(ordinary.url.path, "/approval")
            XCTAssertEqual(NativeAgentRoute(url: ordinary.url), ordinary)
            XCTAssertNotEqual(route, ordinary)

            let components = try XCTUnwrap(URLComponents(url: route.url, resolvingAgainstBaseURL: false))
            for field in ["workflowVersion", "id", "requestToken", "nativeDeliveryNonce"] {
                var missing = components
                missing.queryItems?.removeAll { $0.name == field }
                XCTAssertNil(NativeAgentRoute(url: try XCTUnwrap(missing.url)), field)
            }
            for extra in [URLQueryItem(name: "isToolbarAction", value: "true"),
                          URLQueryItem(name: "id", value: "42")] {
                var invalid = components
                invalid.queryItems?.append(extra)
                XCTAssertNil(NativeAgentRoute(url: try XCTUnwrap(invalid.url)))
            }
            for (field, value) in [("id", "042"), ("nativeDeliveryNonce", "invalid"),
                                   ("requestToken", "invalid"), ("profileIdentifier", "invalid"),
                                   ("workflowVersion", String(ExtensionBridge.workflowVersion + 1))] {
                var invalid = components
                invalid.queryItems?.removeAll { $0.name == field }
                invalid.queryItems?.append(.init(name: field, value: value))
                XCTAssertNil(NativeAgentRoute(url: try XCTUnwrap(invalid.url)))
            }
        }
    }

    private struct Reconciliation: Sendable {
        let reference: NativeMessageDispatcher.ApprovalReference
        let intent: NativeMessageDispatcher.ReconciliationIntent
    }

    private final class ReconciliationLog: Sendable {
        let values = Mutex([Reconciliation]())
    }

    private struct RejectingRPC: PublicRPCForwarding {
        func forward(id: Int, chainId: String, body: String, scope: RPCScope) async -> RPCResponseToExtension {
            fatalError("Toolbar routing must not use RPC")
        }
    }

    private final class Fixture {
        let root: URL
        let origin = "https://wallet.example"
        let bridge: ExtensionBridge
        let log = ReconciliationLog()
        var completesDuringMaterialization = false

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("toolbar-routing-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            bridge = ExtensionBridge(store: ExtensionRequestFileStore(rootURL: root, directoryBoundary: root))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func message(manual: Bool, id: Int = 1) async throws -> [String: Any] {
            guard case .snapshot(let authority) = await bridge.configurationSnapshot(configurationKey: origin, profileIdentifier: nil) else {
                throw CocoaError(.fileReadUnknown)
            }
            return ["id": id, "name": manual ? "switchAccount" : "requestAccounts",
                "provider": manual ? "unknown" : "ethereum", "host": "wallet.example", "configurationKey": origin,
                "authority": authority.version.json, "enqueueAttempt": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                "admissionDeadline": Int(Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000),
                "workflowVersion": ExtensionBridge.workflowVersion,
                "body": manual ? [String: String]() : ["address": "", "chainId": "0x1"]]
        }

        func focus(_ admitted: [String: Any], source: String) async throws -> [String: Any] {
            try await dispatch(["id": XCTUnwrap(admitted["id"] as? Int), "subject": "showApproval",
                "requestToken": XCTUnwrap(admitted["requestToken"] as? String), "configurationKey": origin,
                "workflowVersion": ExtensionBridge.workflowVersion], source: source)
        }

        @discardableResult
        func complete(_ admitted: [String: Any]) async throws -> RequestHandle {
            let id = try XCTUnwrap(admitted["id"] as? Int)
            let token = try XCTUnwrap(RequestToken(rawValue: XCTUnwrap(admitted["requestToken"] as? String)))
            let handle = RequestHandle(id: id, token: token, profileIdentifier: nil)
            let result = await bridge.completeImmediate(handle: handle, resolution: .failure(.userRejected))
            XCTAssertEqual(result, .persisted)
            return handle
        }

        func dispatch(_ message: [String: Any], source: String) async throws -> [String: Any] {
            let log = log
            let bridge = bridge
            let completesDuringMaterialization = completesDuringMaterialization
            let dispatcher = NativeMessageDispatcher(policy: .native, dependencies: .init(
                bridge: bridge, materialize: { handle in
                    if completesDuringMaterialization {
                        _ = await bridge.completeImmediate(handle: handle, resolution: .failure(.userRejected))
                        return .responseReady
                    }
                    return .approvalRequired
                },
                reconcile: { reference, intent in
                    log.values.withLock { $0.append(.init(reference: reference, intent: intent)) }
                    return .opened
                }, pollResponse: { _, _, _ in .unavailable }, rpc: RejectingRPC(),
                popup: { _, _ in .command(.init(status: .ignored, approvalState: nil)) },
                privatePopup: { _ in .command(.init(status: .ignored, approvalState: nil)) },
                openApp: { false }, invalidateNetworkCache: {}
            ), messages: .testingEnglish)
            var context: [String: Any] = ["source": source, "privateBrowsing": false]
            if source == "site" {
                context["site"] = ["host": "wallet.example", "configurationKey": origin]
                context["document"] = ["tabId": 1, "frameId": 0]
            }
            var transport = message
            transport[WireProtocol.nativeContextKey] = context
            let ingress = try XCTUnwrap(NativeRequestContext.extract(from: transport, profileIdentifier: nil))
            return try await dispatcher.dispatch(message: ingress.message, context: ingress.context).json
        }
    }
}
