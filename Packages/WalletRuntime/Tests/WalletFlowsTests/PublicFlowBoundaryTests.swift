import Foundation
import WalletAuthority
import WalletDomain
import WalletRuntimeTestSupport
import XCTest
@testable import WalletFlows

@MainActor
final class PublicFlowBoundaryTests: XCTestCase {
    func testWorkerCanOpenWalletButSiteCannotUseThatRoute() async throws {
        let calls = Calls()
        let dispatcher = makeDispatcher(policy: .native, calls: calls)
        let gate = NativeIngressGate()
        do {
            let site = try gate.admit(transport(subject: "openApp", source: "site"), profileIdentifier: nil)
            defer { site.finish() }
            _ = try await dispatcher.dispatch(site)
            return XCTFail("SECURITY-MUTATION[native.source-role]: Site transport must not open the native wallet")
        } catch NativeIngressGate.Failure.invalidMessage {
        } catch {
            XCTFail("Unexpected admission failure: \(error)")
        }
        let before = await calls.values
        XCTAssertTrue(before.isEmpty)
        let worker = try gate.admit(transport(subject: "openApp", source: "worker"), profileIdentifier: nil)
        defer { worker.finish() }
        let reply = try await dispatcher.dispatch(worker)
        XCTAssertEqual(reply.json["opened"] as? Bool, true)
        let after = await calls.values
        XCTAssertEqual(after, ["open"])
    }

    func testPrivatePopupUsesOnlyItsIsolatedPresentationHandler() async throws {
        let calls = Calls()
        let dispatcher = makeDispatcher(policy: .popup, calls: calls)
        let gate = NativeIngressGate()
        let raw = NSMutableDictionary(dictionary: transport(subject: "getPendingRequests", source: "popup", privateBrowsing: true))
        let request = try gate.admit(raw, profileIdentifier: nil)
        defer { request.finish() }
        raw["subject"] = "openApp"
        raw[WireProtocol.nativeContextKey] = ["source": "worker", "privateBrowsing": false]
        let reply = try await dispatcher.dispatch(request)
        XCTAssertEqual(reply.contract, .popupResponse)
        let recorded = await calls.values
        XCTAssertEqual(recorded, ["privatePopup"])
    }

    func testDappDispatchKeepsTheAdmittedRequestAndTransportContextAfterInputMutation() async throws {
        let calls = Calls()
        let dispatcher = makeDispatcher(policy: .native, calls: calls, bridge: UnavailableBridge(onEnqueue: {
            await calls.record(request: $0.request, profile: $1, privateBrowsing: $2)
        }))
        let profile = UUID()
        let parameters = NSMutableDictionary(dictionary: ["label": "original"])
        let body = NSMutableDictionary(dictionary: ["address": "", "chainId": "0x1"])
        body["object"] = parameters
        let raw = NSMutableDictionary(dictionary: [
            "id": 37, "name": "requestAccounts", "provider": "ethereum", "body": body,
            "host": "wallet.example", "configurationKey": "https://wallet.example",
            "enqueueAttempt": String(repeating: "b", count: 32), "admissionDeadline": 2_000_000_000_000,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "authority": ["context": String(repeating: "a", count: 64), "revisions": ["ethereum": 2, "solana": 3]],
            WireProtocol.nativeContextKey: [
                "source": "site", "privateBrowsing": false,
                "site": ["host": "wallet.example", "configurationKey": "https://wallet.example"],
                "document": ["tabId": 1, "frameId": 0, "documentSession": String(repeating: "a", count: 32)],
            ],
        ])
        let gate = NativeIngressGate()
        let admission = try gate.admit(raw, profileIdentifier: profile)
        defer { admission.finish() }
        parameters["label"] = "changed"
        body["address"] = "changed"
        raw["id"] = 99
        raw["host"] = "other.example"
        raw[WireProtocol.nativeContextKey] = ["source": "worker", "privateBrowsing": true]

        do {
            _ = try await dispatcher.dispatch(admission)
            XCTFail("The fixture bridge must remain unavailable")
        } catch NativeMessageDispatcher.Error.bridgeUnavailable {
        }

        let recorded = await calls.admissions
        let received = try XCTUnwrap(recorded.first)
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(received.request.id, 37)
        XCTAssertEqual(received.request.host, "wallet.example")
        XCTAssertEqual(received.profile, profile)
        XCTAssertFalse(received.privateBrowsing)
        guard case .ethereum(let ethereum) = received.request.body else { return XCTFail("Expected the admitted Ethereum request") }
        XCTAssertEqual(ethereum.address, "")
        XCTAssertEqual(ethereum.parameters?["label"] as? String, "original")
        XCTAssertEqual(gate.statistics.ordinary, 1)
    }

    func testDispatchFailureRetainsAdmissionUntilTheCallerFinishes() async throws {
        let gate = NativeIngressGate()
        let admission = try gate.admit(transport(subject: "openApp", source: "worker"), profileIdentifier: nil)
        defer { admission.finish() }
        let dispatcher = makeDispatcher(policy: .popup, calls: Calls())

        do {
            _ = try await dispatcher.dispatch(admission)
            XCTFail("Popup composition must reject native wallet opening")
        } catch NativeMessageDispatcher.Error.unsupportedOperation {
        }

        XCTAssertEqual(gate.statistics.ordinary, 1)
        admission.finish()
        XCTAssertEqual(gate.statistics.retainedBytes, 0)
        XCTAssertEqual(gate.statistics.ordinary, 0)
    }

    func testCancellationKeepsTheDispatchLeaseUntilTheDependencyExits() async throws {
        let gate = NativeIngressGate()
        let entered = TestGate<Void>()
        let exit = TestGate<Void>()
        defer { exit.resolve(()) }
        let dispatcher = makeDispatcher(policy: .native, calls: Calls(), openApp: {
            entered.resolve(())
            await exit.wait()
            return true
        })
        let raw = transport(subject: "openApp", source: "worker")
        let task = Task {
            let admission = try gate.admit(raw, profileIdentifier: nil)
            defer { admission.finish() }
            return try await dispatcher.dispatch(admission)
        }
        await entered.wait()
        task.cancel()
        XCTAssertEqual(gate.statistics.ordinary, 1)
        XCTAssertGreaterThan(gate.statistics.retainedBytes, 0)
        exit.resolve(())
        _ = try await task.value
        XCTAssertEqual(gate.statistics.ordinary, 0)
        XCTAssertEqual(gate.statistics.retainedBytes, 0)
    }

    func testRPCDispatchTransfersAdmissionOnlyWhenTheRPCServiceDecides() async throws {
        let gate = NativeIngressGate()
        let rpc = SuspendedRPC()
        defer { rpc.admit.resolve(()); rpc.exit.resolve(()) }
        let dispatcher = makeDispatcher(policy: .native, calls: Calls(), rpc: rpc)
        var raw = transport(subject: "rpc", source: "site")
        raw["body"] = "{}"
        raw["chainId"] = "0x1"
        let task = Task {
            let admission = try gate.admit(raw, profileIdentifier: nil)
            defer { admission.finish() }
            return try await dispatcher.dispatch(admission)
        }
        await rpc.entered.wait()
        XCTAssertEqual(gate.statistics.inspecting, 1)
        XCTAssertGreaterThan(gate.statistics.retainedBytes, 0)
        rpc.admit.resolve(())
        await rpc.handedOff.wait()
        XCTAssertEqual(gate.statistics.inspecting, 0)
        XCTAssertEqual(gate.statistics.retainedBytes, 0)

        let ordinary = try gate.admit(transport(subject: "openApp", source: "worker"), profileIdentifier: nil)
        defer { ordinary.finish() }
        rpc.exit.resolve(())
        let response = try await task.value
        XCTAssertEqual(response.json["id"] as? Int, 1)
        XCTAssertEqual(gate.statistics.ordinary, 1)
        ordinary.finish()
        XCTAssertEqual(gate.statistics.retainedBytes, 0)
    }

    private func makeDispatcher(
        policy: NativeMessageDispatcher.ApprovalPolicy,
        calls: Calls,
        bridge: any NativeMessageBridge = UnavailableBridge(),
        rpc: any PublicRPCForwarding = UnavailableRPC(),
        openApp: (@Sendable () async -> Bool)? = nil
    ) -> NativeMessageDispatcher {
        NativeMessageDispatcher(policy: policy, dependencies: .init(
            bridge: bridge,
            materialize: { _ in await calls.record("materialize"); return .unavailable },
            reconcile: { _, _ in await calls.record("reconcile"); return .unavailable },
            pollResponse: { _, _, _, _ in await calls.record("poll"); return .unavailable },
            rpc: rpc,
            popup: { _, _ in await calls.record("popup"); return .queueUnavailable },
            privatePopup: { _ in await calls.record("privatePopup"); return .queueUnavailable },
            openApp: openApp ?? { await calls.record("open"); return true },
            invalidateNetworkCache: {}
        ), messages: AuthorityMessages(values: Dictionary(uniqueKeysWithValues:
            AuthorityMessages.Key.allCases.map { ($0, $0.rawValue) })))
    }

    private func transport(subject: String, source: String, privateBrowsing: Bool = false) -> [String: Any] {
        var context: [String: Any] = ["source": source, "privateBrowsing": privateBrowsing]
        if source == "site" {
            context["site"] = ["host": "wallet.example", "configurationKey": "https://wallet.example"]
            context["document"] = ["tabId": 1, "frameId": 0, "documentSession": "0123456789abcdef0123456789abcdef"]
        }
        return [
            "id": 1, "subject": subject, "workflowVersion": ExtensionBridge.workflowVersion,
            WireProtocol.nativeContextKey: context,
        ]
    }
}

private actor Calls {
    struct Admission: Sendable {
        let request: SafariRequest
        let profile: UUID?
        let privateBrowsing: Bool
    }

    private(set) var values = [String]()
    private(set) var admissions = [Admission]()
    func record(_ value: String) { values.append(value) }
    func record(request: SafariRequest, profile: UUID?, privateBrowsing: Bool) {
        admissions.append(Admission(request: request, profile: profile, privateBrowsing: privateBrowsing))
    }
}

private struct UnavailableRPC: PublicRPCForwarding {
    func forward(
        id: Int, chainId: String, body: String, scope: RPCScope,
        onAdmissionDecision: @escaping @Sendable () -> Void
    ) async -> RPCResponseToExtension {
        onAdmissionDecision()
        return RPCResponseToExtension(upstream: ["id": id, "error": ["code": -32603, "message": "Unavailable"]], expectedResponseID: id)!
    }
}

private struct UnavailableBridge: NativeMessageBridge {
    var onEnqueue: @Sendable (ExtensionBridge.Ingress, UUID?, Bool) async -> Void = { _, _, _ in }

    func enqueue(ingress: ExtensionBridge.Ingress, profileIdentifier: UUID?, privateBrowsing: Bool) async -> ExtensionBridge.EnqueueResult {
        await onEnqueue(ingress, profileIdentifier, privateBrowsing)
        return .unavailable
    }
    func configurationSnapshot(configurationKey: String, profileIdentifier: UUID?) async -> ExtensionBridge.AuthorityReadResult { .unavailable }
    func revoke(configurationKey: String, provider: InpageProvider, attempt: String, expected: RequestAuthorityVersion,
                profileIdentifier: UUID?) async -> ExtensionBridge.AuthorityMutationResult { .unavailable }
    func listRecoveryRequests(profileIdentifier: UUID?) async -> ExtensionBridge.RecoveryRequestsResult { .unavailable }
    func load(handle: RequestHandle) async -> ExtensionBridge.SnapshotResult { .unavailable }
    func authorizeResponseAccess(handle: RequestHandle, configurationKey: String, access: NativeRequestContext.ResponseAccess) async -> ExtensionBridge.ResponseAccessResult { .unavailable }
    func acknowledgeResponse(handle: RequestHandle, configurationKey: String, access: NativeRequestContext.ResponseAccess) async -> ExtensionBridge.StoreMutationResult { .retryablePersistenceFailure }
}

private struct SuspendedRPC: PublicRPCForwarding {
    let entered = TestGate<Void>()
    let admit = TestGate<Void>()
    let handedOff = TestGate<Void>()
    let exit = TestGate<Void>()

    func forward(
        id: Int, chainId: String, body: String, scope: RPCScope,
        onAdmissionDecision: @escaping @Sendable () -> Void
    ) async -> RPCResponseToExtension {
        entered.resolve(())
        await admit.wait()
        onAdmissionDecision()
        handedOff.resolve(())
        await exit.wait()
        onAdmissionDecision()
        return RPCResponseToExtension(upstream: ["id": id, "result": "0x1"], expectedResponseID: id)!
    }
}
