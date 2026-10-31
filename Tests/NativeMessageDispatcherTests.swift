import WalletDomain
import Foundation
import XCTest
@testable import Big_Wallet
@testable import WalletAuthority
@testable import WalletFlows
@testable import WalletNetworking

@MainActor
final class NativeMessageDispatcherTests: XCTestCase {
    func testAdmittedIngressCannotChangeProfileOrEscapePrivateBrowsing() async throws {
        try await withFixture { fixture in
            let profile = UUID()
            let message = try await fixture.connectionMessage(profile: profile)
            let wire = try XCTUnwrap(WireProtocol.object(.dappRequest, value: message))
            func admitted(privateBrowsing: Bool) throws -> ExtensionBridge.Ingress {
                var transport = message
                transport[WireProtocol.nativeContextKey] = [
                    "source": "site", "privateBrowsing": privateBrowsing,
                    "site": ["host": "wallet.example", "configurationKey": fixture.origin],
                    "document": ["tabId": 1, "frameId": 0, "documentSession": "0123456789abcdef0123456789abcdef"],
                ]
                let context = try XCTUnwrap(NativeRequestContext.extract(from: transport, profileIdentifier: profile)).context
                guard case .accepted(let ingress) = ExtensionBridge.admittedIngress(wire: wire, context: context) else {
                    throw CocoaError(.coderInvalidValue)
                }
                return ingress
            }
            guard case .rejected = await fixture.bridge.enqueue(ingress: try admitted(privateBrowsing: false), profileIdentifier: nil) else {
                return XCTFail("Transport-bound ingress must retain its Safari profile")
            }
            guard case .rejected = await fixture.bridge.enqueue(ingress: try admitted(privateBrowsing: true), profileIdentifier: profile) else {
                return XCTFail("Transport-bound ingress cannot become a nonprivate request")
            }
            guard case .accepted = await fixture.bridge.enqueue(ingress: try admitted(privateBrowsing: false), profileIdentifier: profile) else {
                return XCTFail("The original nonprivate transport context must remain admissible")
            }
        }
    }

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

    func testDocumentOwnershipRejectsForeignReplayFocusPollAndAcknowledgement() async throws {
        try await withFixture { fixture in
            let original = NativeRequestContext.DocumentIdentity(tabID: 1, frameID: 0,
                documentID: "original-document", documentSession: String(repeating: "a", count: 32))
            let message = try await fixture.connectionMessage()
            let admitted = try await fixture.dispatch(message, document: original)
            let token = try XCTUnwrap(RequestToken(rawValue: admitted["requestToken"] as? String ?? ""))
            let handle = RequestHandle(id: 1, token: token, profileIdentifier: nil)
            let identity: [String: Any] = ["configurationKey": fixture.origin, "requestToken": token.rawValue]
            for foreign in [
                NativeRequestContext.DocumentIdentity(tabID: 2, frameID: 0,
                    documentID: original.documentID, documentSession: original.documentSession),
                NativeRequestContext.DocumentIdentity(tabID: 1, frameID: 0,
                    documentID: "replacement-document", documentSession: original.documentSession),
                NativeRequestContext.DocumentIdentity(tabID: 1, frameID: 0,
                    documentID: original.documentID, documentSession: String(repeating: "b", count: 32)),
                NativeRequestContext.DocumentIdentity(tabID: 1, frameID: 0,
                    documentID: nil, documentSession: original.documentSession),
            ] {
                fixture.calls.value = []
                let replay = try await fixture.dispatch(message, document: foreign)
                XCTAssertNil(replay["requestToken"])
                await assertFailure(.invalidMessage) {
                    try await fixture.dispatch(fixture.command("showApproval", fields: identity), document: foreign)
                }
                XCTAssertTrue(fixture.calls.value.isEmpty)
                let poll = try await fixture.dispatch(fixture.command("pollResponse", fields:
                    identity.merging(["maintenance": "interactive"]) { _, new in new }), document: foreign)
                XCTAssertEqual(poll["missing"] as? Bool, true)
                let acknowledgement = try await fixture.dispatch(fixture.command("acknowledgeResponse", fields: identity), document: foreign)
                XCTAssertEqual(acknowledgement["missing"] as? Bool, true)
            }
            let rejected = await fixture.bridge.reject(handle: handle)
            XCTAssertEqual(rejected, .persisted)
            let poll = fixture.command("pollResponse", fields: identity.merging(["maintenance": "none"]) { _, new in new })
            let delivered = try await fixture.dispatch(poll, document: original)
            XCTAssertNotNil(delivered["response"])
            let acknowledgement = try await fixture.dispatch(fixture.command("acknowledgeResponse", fields: identity), document: original)
            XCTAssertEqual(acknowledgement["acknowledged"] as? Bool, true)
        }
    }

    func testManualSwitchCoalescingKeepsDocumentAndWorkerOwnersSeparate() async throws {
        try await withFixture { fixture in
            let firstDocument = NativeRequestContext.DocumentIdentity(tabID: 1, frameID: 0,
                documentID: nil, documentSession: String(repeating: "a", count: 32))
            let secondDocument = NativeRequestContext.DocumentIdentity(tabID: 1, frameID: 0,
                documentID: nil, documentSession: String(repeating: "b", count: 32))
            func manualMessage() async throws -> [String: Any] {
                var message = try await fixture.connectionMessage()
                message["provider"] = "unknown"
                message["name"] = "switchAccount"
                message["body"] = [String: Any]()
                return message
            }
            let first = try await fixture.dispatch(try await manualMessage(), document: firstDocument)
            let repeated = try await fixture.dispatch(try await manualMessage(), document: firstDocument)
            let second = try await fixture.dispatch(try await manualMessage(), document: secondDocument)
            let worker = try await fixture.dispatch(try await manualMessage(), source: "worker")
            let repeatedWorker = try await fixture.dispatch(try await manualMessage(), source: "worker")
            XCTAssertEqual(repeated["admissionKind"] as? String, "coalesced")
            XCTAssertEqual(repeated["requestToken"] as? String, first["requestToken"] as? String)
            XCTAssertEqual(second["admissionKind"] as? String, "new")
            XCTAssertNotEqual(second["requestToken"] as? String, first["requestToken"] as? String)
            XCTAssertEqual(worker["admissionKind"] as? String, "new")
            XCTAssertEqual(repeatedWorker["admissionKind"] as? String, "coalesced")
            XCTAssertEqual(repeatedWorker["requestToken"] as? String, worker["requestToken"] as? String)
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
            XCTAssertEqual(try canonical(result), try canonical([
                "id": 1, "name": "requestAccounts", "provider": "ethereum",
                "kind": "error", "approvalCommitted": false, "authorizationFailure": false,
                "error": ["code": 4200, "message": AuthorityStrings.privateBrowsingUnsupported],
            ]))
            XCTAssertTrue(fixture.calls.value.isEmpty)
            guard case .available(let requests) = await fixture.bridge.listRecoveryRequests(profileIdentifier: nil) else {
                return XCTFail("Expected empty store")
            }
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testUnauthorizedDappResponsePreservesAuthorityAndCorrelation() async throws {
        try await withFixture { fixture in
            var message = try await fixture.connectionMessage()
            message["name"] = "signPersonalMessage"
            message["body"] = [
                "address": "0x0000000000000000000000000000000000000001",
                "chainId": "0x1", "object": ["data": "0x01"],
            ]
            let result = try await fixture.dispatch(message)
            guard case .snapshot(let authority) = await fixture.bridge.configurationSnapshot(
                configurationKey: fixture.origin, profileIdentifier: nil
            ) else { return XCTFail("Expected disconnected authority") }
            XCTAssertEqual(try canonical(result), try canonical([
                "id": 1,
                "response": [
                    "id": 1, "name": "signPersonalMessage", "provider": "ethereum",
                    "kind": "error", "approvalCommitted": false, "authorizationFailure": false,
                    "error": ["code": 4100, "message": AuthorityStrings.providerNotReady],
                ],
                "state": authority.json,
            ]))
            XCTAssertEqual(fixture.bridgeCalls.value, ["enqueue"])
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
            let token = try XCTUnwrap(RequestToken(rawValue: admitted["requestToken"] as? String ?? ""))
            let handle = RequestHandle(id: 1, token: token, profileIdentifier: nil)
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

    func testRPCRejectsValidatedResponseForAnotherRequest() async throws {
        try await withFixture(rpcOperation: { _, execution in
            try execution.markDispatched()
            return RPCResponseToExtension(upstream: ["id": 2, "result": "wrong request"], expectedResponseID: 2)!
        }) { fixture in
            let response = try await fixture.dispatch(fixture.command("rpc", fields: [
                "chainId": "0x1", "body": #"{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"}"#,
            ]))
            XCTAssertEqual(response["id"] as? Int, 1)
            XCTAssertNil(response["result"])
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32_603)
            let data = try XCTUnwrap(error["data"] as? [String: Any])
            XCTAssertEqual(data["reason"] as? String, "transport")
            XCTAssertEqual(data["dispatched"] as? Bool, true)
        }
    }

    func testRPCAdmissionRejectsMalformedAndProhibitedBodiesBeforeNetworkLookup() async throws {
        try await withFixture { fixture in
            let bodies: [(String, Int)] = [
                ("{", -32_700),
                ("{}", -32_600),
                (#"[{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"}]"#, -32_600),
                (#"{"jsonrpc":"2.0","method":"eth_blockNumber"}"#, -32_600),
                (#"{"jsonrpc":"2.0","id":true,"method":"eth_blockNumber"}"#, -32_600),
                (#"{"jsonrpc":"2.0","id":2,"method":"eth_blockNumber"}"#, -32_600),
                (#"{"jsonrpc":"2.0","id":1,"method":"eth_sendTransaction"}"#, 4_200),
                (#"{"jsonrpc":"2.0","id":1,"method":"  ADMIN_addPeer  "}"#, 4_200),
                (#"{"jsonrpc":"2.0","id":1,"method":"debug_setHead"}"#, 4_200),
            ]
            for (body, code) in bodies {
                let response = try await fixture.dispatch(fixture.command("rpc", fields: ["chainId": "0x1", "body": body]))
                let error = try XCTUnwrap(response["error"] as? [String: Any])
                XCTAssertEqual(response["id"] as? Int, 1)
                XCTAssertEqual(error["code"] as? Int, code)
                XCTAssertEqual((error["data"] as? [String: Any])?["dispatched"] as? Bool, false)
            }
            XCTAssertTrue(fixture.calls.value.isEmpty)
            XCTAssertEqual(fixture.rpcNetworkCalls.value, 0)
        }
    }

    func testRPCUsesItsOwnRequestLimitInsteadOfTheApprovalPayloadLimit() async throws {
        try await withFixture { fixture in
            let payload: [String: Any] = [
                "jsonrpc": "2.0", "id": 1, "method": "vendor_simulate",
                "params": ["input": String(repeating: "x", count: ExtensionBridge.maximumPayloadBytes + 1)],
            ]
            let body = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            let response = try await fixture.dispatch(fixture.command("rpc", fields: ["chainId": "0x1", "body": body]))
            XCTAssertEqual(response["result"] as? String, "0x1")
            XCTAssertEqual(fixture.calls.value, ["rpc"])
        }
        var limits = SafariRPCLimits.live
        limits.maximumRequestBytes = 128
        try await withFixture(rpcLimits: limits) { fixture in
            let response = try await fixture.dispatch(fixture.command("rpc", fields: [
                "chainId": "0x1", "body": String(repeating: "x", count: 129),
            ]))
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32_005)
            XCTAssertEqual((error["data"] as? [String: Any])?["reason"] as? String, "request_too_large")
            XCTAssertEqual(fixture.rpcNetworkCalls.value, 0)
        }
    }

    func testPrivilegedRPCAliasesNeverReachEndpointAuthorizationOrNetwork() async throws {
        try await withFixture { fixture in
            for method in [
                "eth_resend", "parity_postTransaction", "debug_deleteChainSlice", "debug_resetHead",
                "debug_verbosity", "debug_vmodule", "eth_sendTransactionSync",
                "debug_clearTxpool", "tenderly_setBalance", "tenderly_addBalance",
                "debug_insertReceipts", "debug_migrateReceipts",
                "testing_commitBlockV1",
                "parity_postSign", "parity_signMessage", "parity_setMode",
                "parity_acceptNonReservedPeers", "parity_addReservedPeer", "parity_dropNonReservedPeers",
                "parity_executeUpgrade", "parity_removeReservedPeer", "parity_setAuthor", "parity_setChain",
                "parity_setEngineSigner", "parity_setExtraData", "parity_setGasCeilTarget", "parity_setGasFloorTarget",
                "parity_setMaxTransactionGas", "parity_setMinGasPrice", "parity_setTransactionsLimit",
                "parity_changePassword", "parity_deriveAddressHash", "parity_deriveAddressIndex", "parity_importGethAccounts",
                "parity_killAccount", "parity_newAccountFromPhrase", "parity_newAccountFromSecret", "parity_newAccountFromWallet",
                "parity_removeAddress", "parity_setAccountMeta", "parity_setAccountName", "parity_changeVault",
                "parity_changeVaultPassword", "parity_closeVault", "parity_newVault", "parity_openVault", "parity_setVaultMeta",
                "parity_hardwarePinMatrixAck", "parity_removeTransaction", "parity_exportAccount", "parity_testPassword",
                "parity_decryptMessage",
            ] {
                for variant in [method, " \n" + method.uppercased() + "\t"] {
                    let payload: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": variant, "params": []]
                    let body = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                    let response = try await fixture.dispatch(fixture.command("rpc", fields: ["chainId": "0x1", "body": body]))
                    let error = try XCTUnwrap(response["error"] as? [String: Any])
                    let data = try XCTUnwrap(error["data"] as? [String: Any])
                    XCTAssertEqual(response["id"] as? Int, 1)
                    XCTAssertEqual(error["code"] as? Int, 4_200, variant)
                    XCTAssertEqual(data["reason"] as? String, "prohibited_method", variant)
                    XCTAssertEqual(data["dispatched"] as? Bool, false, variant)
                }
            }
            XCTAssertEqual(fixture.rpcNetworkCalls.value, 0)
            XCTAssertTrue(fixture.calls.value.isEmpty)
        }
    }

    func testBadBlockFileOutputIsRejectedBeforeNetworkWhileReadsAreForwarded() async throws {
        try await withFixture { fixture in
            let writes: [Any] = [["/tmp/bad-blocks.json"], ["file": "/tmp/bad-blocks.json"]]
            for method in ["debug_getBadBlocks", " \nDEBUG_GETBADBLOCKS\t"] {
                for params in writes {
                    let payload: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
                    let body = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                    let response = try await fixture.dispatch(fixture.command("rpc", fields: ["chainId": "0x1", "body": body]))
                    let error = try XCTUnwrap(response["error"] as? [String: Any])
                    let data = try XCTUnwrap(error["data"] as? [String: Any])
                    XCTAssertEqual(response["id"] as? Int, 1)
                    XCTAssertEqual(error["code"] as? Int, 4_200)
                    XCTAssertEqual(data["reason"] as? String, "prohibited_method")
                    XCTAssertEqual(data["dispatched"] as? Bool, false)
                }
            }
            XCTAssertEqual(fixture.rpcNetworkCalls.value, 0)
            XCTAssertTrue(fixture.calls.value.isEmpty)

            let reads: [Any?] = [nil, NSNull(), [Any](), [NSNull()]]
            for params in reads {
                var payload: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "debug_getBadBlocks"]
                payload["params"] = params
                let body = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                let response = try await fixture.dispatch(fixture.command("rpc", fields: ["chainId": "0x1", "body": body]))
                XCTAssertEqual(response["result"] as? String, "0x1")
            }
            XCTAssertEqual(fixture.rpcNetworkCalls.value, reads.count)
            XCTAssertEqual(fixture.calls.value, Array(repeating: "rpc", count: reads.count))
        }
    }

    func testUnavailableRPCEndpointReturnsTransportFailureWithoutDispatching() async throws {
        try await withFixture { fixture in
            fixture.rpcNetworkAvailable = false
            let response = try await fixture.dispatch(fixture.command("rpc", fields: [
                "chainId": "0x1", "body": #"{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"}"#,
            ]))
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32_603)
            let data = try XCTUnwrap(error["data"] as? [String: Any])
            XCTAssertEqual(data["reason"] as? String, "transport")
            XCTAssertEqual(data["dispatched"] as? Bool, false)
            XCTAssertEqual(fixture.rpcNetworkCalls.value, 1)
            XCTAssertTrue(fixture.calls.value.isEmpty)
        }
    }

    func testSaturatedRPCDoesNotBlockApprovalRejectionOrRecovery() async throws {
        let started = TestGate<Void>()
        let release = TestGate<Void>()
        var limits = SafariRPCLimits.live
        limits.maximumActiveRequests = 1
        limits.maximumActivePerOrigin = 1
        limits.maximumOutstandingRequests = 1
        limits.maximumOutstandingPerOrigin = 1
        try await withFixture(rpcLimits: limits, rpcOperation: { request, execution in
            try execution.markDispatched()
            started.resolve(())
            await release.wait()
            return RPCResponseToExtension(upstream: ["id": request.id, "result": "0x1"], expectedResponseID: request.id)!
        }) { fixture in
            let rpc = fixture.command("rpc", fields: [
                "chainId": "0x1", "body": #"{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"}"#,
            ])
            let pending = Task {
                let response = try await fixture.dispatch(rpc)
                return try XCTUnwrap(WireProtocol.JSONObject(response))
            }
            defer { release.resolve(()) }
            await started.wait()
            let busy = try await fixture.dispatch(rpc)
            XCTAssertEqual((busy["error"] as? [String: Any])?["code"] as? Int, -32_005)

            let admission = try await fixture.dispatch(try await fixture.connectionMessage())
            let token = try XCTUnwrap(admission["requestToken"] as? String)
            guard let requestToken = RequestToken(rawValue: token) else {
                return XCTFail("Expected request token")
            }
            let handle = RequestHandle(id: 1, token: requestToken, profileIdentifier: nil)
            let rejected = await fixture.bridge.reject(handle: handle)
            XCTAssertEqual(rejected, .persisted)
            let recovery = try await fixture.dispatch(fixture.command("getRecoveryRequests"), source: "worker")
            XCTAssertNotNil(recovery["requests"])
            let polled = try await fixture.dispatch(fixture.command("pollResponse", fields: [
                "configurationKey": fixture.origin, "requestToken": token, "maintenance": "none",
            ]))
            XCTAssertNotNil(polled["response"])
            XCTAssertTrue(fixture.calls.value.contains("materialize"))
            release.resolve(())
            let completedRPC = try await pending.value
            XCTAssertEqual(completedRPC["result"] as? String, "0x1")
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
            let token = try XCTUnwrap(RequestToken(rawValue: admitted["requestToken"] as? String ?? ""))
            let handle = RequestHandle(id: 1, token: token, profileIdentifier: profile)
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

    private func withFixture(
        rpcLimits: SafariRPCLimits = .live,
        rpcOperation: SafariRPCService.Operation? = nil,
        _ operation: (Fixture) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatcher-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(Fixture(root: root, rpcLimits: rpcLimits, rpcOperation: rpcOperation))
    }

    private final class Fixture {
        let origin = "https://wallet.example"
        let bridge: ExtensionBridge
        let calls = LockedTestValue([String]())
        let bridgeCalls = LockedTestValue([String]())
        let rpcNetworkCalls = LockedTestValue(0)
        var rpcNetworkAvailable = true
        let rpcService: SafariRPCService
        let rpcOperation: SafariRPCService.Operation?

        init(root: URL, rpcLimits: SafariRPCLimits, rpcOperation: SafariRPCService.Operation?) {
            bridge = ExtensionBridge(store: ExtensionRequestFileStore(rootURL: root, directoryBoundary: root))
            rpcService = SafariRPCService(limits: rpcLimits)
            self.rpcOperation = rpcOperation
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
            siteOrigin: String? = nil,
            document: NativeRequestContext.DocumentIdentity = .init(tabID: 1, frameID: 0,
                documentID: nil, documentSession: "0123456789abcdef0123456789abcdef")
        ) async throws -> [String: Any] {
            let calls = calls
            let bridge = bridge
            let bridgeCalls = bridgeCalls
            let rpcNetworkCalls = rpcNetworkCalls
            let rpcNetworkAvailable = rpcNetworkAvailable
            let rpcOperation = rpcOperation
            let popup: @Sendable () -> PopupResponse = {
                .queue(.init(requests: [], completedResponses: [], strings: Strings.popup, layoutDirection: .ltr))
            }
            let rpc = PublicRPCForwarder(service: rpcService,
                network: { chain in
                    rpcNetworkCalls.withValue { $0 += 1 }
                    guard rpcNetworkAvailable else { return nil }
                    return .init(network: EthereumNetwork(chainId: chain, name: "Fixture", symbol: "ETH",
                        rpcEndpoint: .unauthenticated(URL(string: "https://rpc.example")!),
                        isTestnet: true, mightShowPrice: false, explorer: nil), source: .custom)
                },
                send: { _, request, execution in
                    if let rpcOperation { return try await rpcOperation(request, execution) }
                    try execution.markDispatched()
                    calls.withValue { $0.append("rpc") }
                    return RPCResponseToExtension(
                        upstream: ["id": request.id, "result": "0x1", "privateUpstreamField": "discard"],
                        expectedResponseID: request.id
                    )!
                }
            )
            let dispatcher = NativeMessageDispatcher(policy: policy, dependencies: .init(
                bridge: TrackingBridge(bridge: bridge, calls: bridgeCalls),
                materialize: { _ in calls.withValue { $0.append("materialize") }; return .approvalRequired },
                reconcile: { _, _ in calls.withValue { $0.append("reconcile") }; return .opened },
                pollResponse: { handle, origin, _, access in
                    bridgeCalls.withValue { $0.append("poll") }
                    return await bridge.prepareResponseDelivery(id: handle.id, configurationKey: origin,
                        requestToken: handle.requestToken, profileIdentifier: handle.profileIdentifier, access: access)
                },
                rpc: rpc,
                popup: { _, _ in calls.withValue { $0.append("popup") }; return popup() },
                privatePopup: { _ in calls.withValue { $0.append("privatePopup") }; return popup() },
                openApp: { calls.withValue { $0.append("open") }; return true },
                invalidateNetworkCache: { calls.withValue { $0.append("invalidate") } }
            ), messages: .testingEnglish)
            var transportContext: [String: Any] = ["source": source, "privateBrowsing": privateBrowsing]
            if source == "site" {
                let origin = siteOrigin ?? self.origin
                transportContext["site"] = ["host": try XCTUnwrap(URL(string: origin)?.host), "configurationKey": origin]
                var documentFields: [String: Any] = ["tabId": document.tabID, "frameId": document.frameID,
                    "documentSession": document.documentSession]
                documentFields["documentId"] = document.documentID
                transportContext["document"] = documentFields
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
                    expected: RequestAuthorityVersion, profileIdentifier: UUID?) async -> ExtensionBridge.AuthorityMutationResult {
            calls.withValue { $0.append("revoke") }
            return await bridge.revoke(configurationKey: configurationKey, provider: provider, attempt: attempt,
                                       expected: expected, profileIdentifier: profileIdentifier)
        }

        func listRecoveryRequests(profileIdentifier: UUID?) async -> ExtensionBridge.RecoveryRequestsResult {
            calls.withValue { $0.append("recovery") }
            return await bridge.listRecoveryRequests(profileIdentifier: profileIdentifier)
        }

        func load(handle: RequestHandle) async -> ExtensionBridge.SnapshotResult {
            calls.withValue { $0.append("load") }
            return await bridge.load(handle: handle)
        }

        func authorizeResponseAccess(handle: RequestHandle, configurationKey: String, access: NativeRequestContext.ResponseAccess) async -> ExtensionBridge.ResponseAccessResult {
            await bridge.authorizeResponseAccess(handle: handle, configurationKey: configurationKey, access: access)
        }

        func acknowledgeResponse(handle: RequestHandle, configurationKey: String, access: NativeRequestContext.ResponseAccess) async -> ExtensionBridge.StoreMutationResult {
            calls.withValue { $0.append("acknowledge") }
            return await bridge.acknowledgeResponse(handle: handle, configurationKey: configurationKey, access: access)
        }
    }
}
