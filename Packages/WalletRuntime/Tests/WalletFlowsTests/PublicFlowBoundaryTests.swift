import Foundation
import WalletAuthority
import WalletDomain
import XCTest
@testable import WalletFlows

@MainActor
final class PublicFlowBoundaryTests: XCTestCase {
    func testWorkerCanOpenWalletButSiteCannotUseThatRoute() async throws {
        let calls = Calls()
        let dispatcher = makeDispatcher(policy: .native, calls: calls)
        let site = try transport(subject: "openApp", source: "site")
        do {
            _ = try await dispatcher.dispatch(message: site.message, context: site.context)
            XCTFail("Site transport must not open the native wallet")
        } catch {
            XCTAssertEqual(error as? NativeMessageDispatcher.Error, .invalidMessage)
        }
        let before = await calls.values
        XCTAssertTrue(before.isEmpty)
        let worker = try transport(subject: "openApp", source: "worker")
        let reply = try await dispatcher.dispatch(message: worker.message, context: worker.context)
        XCTAssertEqual(reply.json["opened"] as? Bool, true)
        let after = await calls.values
        XCTAssertEqual(after, ["open"])
    }

    func testPrivatePopupUsesOnlyItsIsolatedPresentationHandler() async throws {
        let calls = Calls()
        let dispatcher = makeDispatcher(policy: .popup, calls: calls)
        let request = try transport(subject: "getPendingRequests", source: "popup", privateBrowsing: true)
        let reply = try await dispatcher.dispatch(message: request.message, context: request.context)
        XCTAssertEqual(reply.contract, .popupResponse)
        let recorded = await calls.values
        XCTAssertEqual(recorded, ["privatePopup"])
    }

    private func makeDispatcher(policy: NativeMessageDispatcher.ApprovalPolicy, calls: Calls) -> NativeMessageDispatcher {
        NativeMessageDispatcher(policy: policy, dependencies: .init(
            bridge: UnavailableBridge(),
            materialize: { _ in await calls.record("materialize"); return .unavailable },
            reconcile: { _, _ in await calls.record("reconcile"); return .unavailable },
            pollResponse: { _, _, _ in await calls.record("poll"); return .unavailable },
            rpc: UnavailableRPC(),
            popup: { _, _ in await calls.record("popup"); return .queueUnavailable },
            privatePopup: { _ in await calls.record("privatePopup"); return .queueUnavailable },
            openApp: { await calls.record("open"); return true },
            invalidateNetworkCache: {}
        ), messages: AuthorityMessages(values: Dictionary(uniqueKeysWithValues:
            AuthorityMessages.Key.allCases.map { ($0, $0.rawValue) })))
    }

    private func transport(subject: String, source: String, privateBrowsing: Bool = false) throws
        -> (message: WireProtocol.JSONObject, context: NativeRequestContext) {
        var context: [String: Any] = ["source": source, "privateBrowsing": privateBrowsing]
        if source == "site" {
            context["site"] = ["host": "wallet.example", "configurationKey": "https://wallet.example"]
            context["document"] = ["tabId": 1, "frameId": 0]
        }
        return try XCTUnwrap(NativeRequestContext.extract(from: [
            "id": 1, "subject": subject, "workflowVersion": ExtensionBridge.workflowVersion,
            WireProtocol.nativeContextKey: context,
        ], profileIdentifier: nil))
    }
}

private actor Calls {
    private(set) var values = [String]()
    func record(_ value: String) { values.append(value) }
}

private struct UnavailableRPC: PublicRPCForwarding {
    func forward(id: Int, chainId: String, body: String, scope: RPCScope) async -> RPCResponseToExtension {
        RPCResponseToExtension(upstream: ["id": id, "error": ["code": -32603, "message": "Unavailable"]], expectedResponseID: id)!
    }
}

private struct UnavailableBridge: NativeMessageBridge {
    func enqueue(ingress: ExtensionBridge.Ingress, profileIdentifier: UUID?, privateBrowsing: Bool) async -> ExtensionBridge.EnqueueResult { .unavailable }
    func configurationSnapshot(configurationKey: String, profileIdentifier: UUID?) async -> ExtensionBridge.AuthorityReadResult { .unavailable }
    func revoke(configurationKey: String, provider: InpageProvider, attempt: String, expected: RequestAuthorityVersion,
                profileIdentifier: UUID?) async -> ExtensionBridge.AuthorityMutationResult { .unavailable }
    func listRecoveryRequests(profileIdentifier: UUID?) async -> ExtensionBridge.RecoveryRequestsResult { .unavailable }
    func load(handle: RequestHandle) async -> ExtensionBridge.SnapshotResult { .unavailable }
    func acknowledgeResponse(handle: RequestHandle, configurationKey: String) async -> ExtensionBridge.StoreMutationResult { .retryablePersistenceFailure }
}
