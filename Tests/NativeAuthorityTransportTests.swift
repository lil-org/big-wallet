import Foundation
import XCTest
@testable import Big_Wallet

final class NativeAuthorityTransportTests: XCTestCase {
    private let context = String(repeating: "a", count: 64)
    private let requestToken = "00000000-0000-4000-8000-000000000001"

    private var authority: [String: Any] {
        ["context": context, "revisions": ["ethereum": 2, "solana": 3]]
    }

    private func decode(_ body: [String: Any]) throws -> InternalSafariRequest {
        var body = body
        body["id"] = 1
        body["workflowVersion"] = ExtensionBridge.workflowVersion
        return try JSONDecoder().decode(
            InternalSafariRequest.self,
            from: JSONSerialization.data(withJSONObject: body)
        )
    }

    func testSnapshotReadCannotChooseItsNativeProfile() throws {
        let body: [String: Any] = [
            "subject": "getLatestConfiguration",
            "configurationKey": "https://wallet.example",
        ]
        guard case .page(.getLatestConfiguration(let origin)) = try decode(body).command else {
            return XCTFail("Expected snapshot read")
        }
        XCTAssertEqual(origin, "https://wallet.example")
        for field in ["profileIdentifier", "state", "revisions", "host"] {
            var invalid = body
            invalid[field] = "untrusted"
            XCTAssertThrowsError(try decode(invalid), field)
        }
    }

    func testRevocationRequiresAnExactNativeVersionAndAttempt() throws {
        let body: [String: Any] = [
            "subject": "disconnect",
            "configurationKey": "https://wallet.example",
            "provider": "ethereum",
            "attempt": String(repeating: "b", count: 32),
            "authority": authority,
        ]
        guard case .page(.disconnect(let identity)) = try decode(body).command else {
            return XCTFail("Expected revocation")
        }
        XCTAssertEqual(identity.authority.context, context)
        XCTAssertEqual(identity.authority.revisions.ethereum, 2)
        for badProvider in ["unknown", "multiple", ""] {
            var invalid = body
            invalid["provider"] = badProvider
            XCTAssertThrowsError(try decode(invalid))
        }
        for badContext in ["", String(repeating: "A", count: 64), String(repeating: "a", count: 63)] {
            var invalid = body
            var version = authority
            version["context"] = badContext
            invalid["authority"] = version
            XCTAssertThrowsError(try decode(invalid))
        }
        var invalid = body
        var version = authority
        version["permission"] = true
        invalid["authority"] = version
        XCTAssertThrowsError(try decode(invalid))
        invalid = body
        invalid["attempt"] = "not-an-attempt"
        XCTAssertThrowsError(try decode(invalid))
    }

    func testApprovalCannotSupplyAuthorityOrExtendItsDeadline() throws {
        let body: [String: Any] = [
            "subject": "approveRequest",
            "requestToken": requestToken,
            "reviewToken": requestToken,
            "payload": [:],
        ]
        guard case .popup(.approveRequest) = try decode(body).command else {
            return XCTFail("Expected approval")
        }
        for (field, value): (String, Any) in [
            ("executionDeadline", 9_000_000_000_000),
            ("revisions", ["ethereum": 2, "solana": 3]),
            ("authority", authority),
        ] {
            var invalid = body
            invalid["payload"] = [field: value]
            XCTAssertThrowsError(try decode(invalid), field)
        }
        XCTAssertThrowsError(try decode([
            "subject": "executeNativeApproval",
            "requestToken": requestToken,
            "configurationKey": "https://wallet.example",
            "claimID": requestToken,
            "executionDeadline": 9_000_000_000_000,
            "revisions": ["ethereum": 2, "solana": 3],
        ]))
    }

    func testSelectedAccountsRetainTheExactPopupWireShape() throws {
        let selected: [String: Any] = [
            "walletId": "selected-wallet",
            "address": "0x" + String(repeating: "AB", count: 20),
            "coin": "ethereum",
            "derivationPath": "m/44'/60'/0'/0/1",
        ]
        func approval(_ selected: [String: Any]) throws -> InternalSafariRequest {
            try decode([
                "subject": "approveRequest",
                "requestToken": requestToken,
                "reviewToken": requestToken,
                "payload": ["selectedAccounts": [selected]],
            ])
        }
        guard case .popup(.approveRequest(_, let payload)) = try approval(selected).command,
              let account = payload.selectedAccounts?.first else {
            return XCTFail("Expected the popup account selection")
        }
        XCTAssertEqual(account.walletId, selected["walletId"] as? String)
        XCTAssertEqual(account.address, selected["address"] as? String)
        XCTAssertEqual(account.coin, .ethereum)
        XCTAssertEqual(account.derivationPath, selected["derivationPath"] as? String)

        for field in selected.keys {
            var missing = selected
            missing.removeValue(forKey: field)
            XCTAssertThrowsError(try approval(missing), field)
            var wrongType = selected
            wrongType[field] = 1
            XCTAssertThrowsError(try approval(wrongType), field)
        }
        for field in ["walletID", "normalizedAddress", "publicKey"] {
            var extra = selected
            extra[field] = "unexpected"
            XCTAssertThrowsError(try approval(extra), field)
        }
        for provider in [InpageProvider.unknown, .multiple] {
            var unsupported = selected
            unsupported["coin"] = provider.rawValue
            XCTAssertThrowsError(try approval(unsupported))
        }
    }

    func testInternalCommandRejectsMalformedNumbersAndExplicitNullOptionals() throws {
        let valid: [String: Any] = [
            "id": 1,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "subject": "approveRequest",
            "requestToken": requestToken,
            "reviewToken": requestToken,
            "payload": [:],
        ]
        func parse(_ json: [String: Any]) throws -> InternalSafariRequest {
            try JSONDecoder().decode(InternalSafariRequest.self, from: JSONSerialization.data(withJSONObject: json))
        }
        for invalidID: Any in [true, 1.5, 9_007_199_254_740_992] {
            var invalid = valid
            invalid["id"] = invalidID
            XCTAssertThrowsError(try parse(invalid))
        }
        for field in ["selectedAccounts", "chainId", "cluster"] {
            var invalid = valid
            invalid["payload"] = [field: NSNull()]
            XCTAssertThrowsError(try parse(invalid), field)
        }
        var invalidVersion = valid
        invalidVersion["workflowVersion"] = true
        XCTAssertThrowsError(try parse(invalidVersion))
    }

    func testRPCRelayProjectsMetadataAndPreservesOpaquePayloads() throws {
        let payload: [String: Any] = [
            "vendor": ["unknown": [1, NSNull(), true], "__proto__": "literal"],
            "data": ["nested": ["customTransactionField": "preserved"]],
        ]
        for field in ["result", "error"] {
            let upstream: [String: Any] = [
                "id": 91, "jsonrpc": "2.0", field: payload,
                "providerMetadata": ["requestID": "vendor-id"],
            ]
            let response = try XCTUnwrap(RPCResponseToExtension(upstream: upstream, expectedResponseID: 91))
            XCTAssertEqual(response.json as NSDictionary, [
                "id": 91, "jsonrpc": "2.0", field: payload,
            ] as NSDictionary)
            XCTAssertNotNil(upstream["providerMetadata"])
        }
        let nullResult = try XCTUnwrap(RPCResponseToExtension(
            upstream: ["id": 91, "result": NSNull(), "providerMetadata": true],
            expectedResponseID: 91
        ))
        XCTAssertTrue(nullResult.json["result"] is NSNull)
    }

    func testRPCRelayRejectsMalformedCorrelationAndAmbiguousPayloads() {
        let valid: [String: Any] = ["id": 91, "jsonrpc": "2.0", "result": [:]]
        for invalidID: Any in [true, 91.5, "91", NSNull(), 92] {
            var invalid = valid
            invalid["id"] = invalidID
            XCTAssertNil(RPCResponseToExtension(upstream: invalid, expectedResponseID: 91))
        }
        for invalidVersion: Any in ["1.0", 2, true, NSNull()] {
            var invalid = valid
            invalid["jsonrpc"] = invalidVersion
            XCTAssertNil(RPCResponseToExtension(upstream: invalid, expectedResponseID: 91))
        }
        var ambiguous = valid
        ambiguous["error"] = ["code": -32603, "data": ["custom": true]]
        XCTAssertNil(RPCResponseToExtension(upstream: ambiguous, expectedResponseID: 91))
        XCTAssertNil(RPCResponseToExtension(upstream: ["id": 91], expectedResponseID: 91))
    }

    func testNativeErrorCodeRetainsTheLargestSwiftInteger() throws {
        let request = try XCTUnwrap(SafariRequest(json: [
            "id": 91, "name": "signMessage", "provider": "ethereum",
            "body": ["address": "", "chainId": "0x1"],
            "host": "wallet.example", "configurationKey": "https://wallet.example",
            "enqueueAttempt": String(repeating: "a", count: 32),
            "admissionDeadline": 2_000_000_900_000,
            "workflowVersion": ExtensionBridge.workflowVersion,
        ]))
        let produced = ResponseToExtension(for: request, payload: .error(.init(
            message: "Upstream code", code: Int.max
        )))
        XCTAssertTrue(WireProtocol.validate(.nativeResponse, value: produced.json))
        let decoded = try XCTUnwrap(ResponseToExtension(json: produced.json))
        guard case .error(let error) = decoded.payload else { return XCTFail("Expected native error") }
        XCTAssertEqual(error.code, Int.max)
    }

    func testRecoveryDiscoveryCannotSupplyAProfileOrGrant() throws {
        guard case .worker(.getRecoveryRequests) = try decode([
            "subject": "getRecoveryRequests",
        ]).command else {
            return XCTFail("Expected recovery discovery")
        }
        for key in ["profileIdentifier", "configurationKey", "authority"] {
            XCTAssertThrowsError(try decode([
                "subject": "getRecoveryRequests", key: "untrusted",
            ]))
        }
    }

    func testPublicSnapshotDoesNotRevealNativeWalletIdentity() throws {
        let descriptor = WalletAccountDescriptor(
            walletID: "private-wallet-id", coin: .ethereum,
            normalizedAddress: "0x" + String(repeating: "1", count: 40),
            derivationPath: "m/44'/60'/0'/0/0"
        )
        let version = try XCTUnwrap(ExtensionBridge.AuthorityVersion(rawValue: authority))
        let snapshot = ExtensionBridge.AuthoritySnapshot(
            version: version, ethereumAccount: descriptor,
            ethereumChainId: "0x1", solanaAccount: nil
        )
        let json = snapshot.json
        XCTAssertEqual(Set(json.keys), ["context", "revisions", "ethereum", "solana"])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        XCTAssertFalse(encoded.contains(descriptor.walletID))
        XCTAssertFalse(encoded.contains("derivationPath"))
        XCTAssertFalse(encoded.contains("profileIdentifier"))
    }

    @MainActor
    func testPersonalRecoverySurvivesUnrelatedOriginPermissionChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-authority-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = ExtensionBridge(store: ExtensionRequestFileStore(
            rootURL: directory, directoryBoundary: directory
        ))
        let origin = "https://wallet.example"
        guard case .snapshot(let initial) = await bridge.configurationSnapshot(
            configurationKey: origin, profileIdentifier: nil
        ), case .snapshot(let other) = await bridge.configurationSnapshot(
            configurationKey: "https://other.example", profileIdentifier: nil
        ), case .revoked = await bridge.revoke(
            configurationKey: "https://other.example", provider: .ethereum,
            attempt: String(repeating: "1", count: 32), expected: other.version,
            profileIdentifier: nil
        ) else { return XCTFail("Expected independent native snapshots and revocation") }

        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let message = Data("recover without a connected account".utf8)
        let signature = try Ethereum.signPersonalMessage(data: message, privateKey: key)
        let object: [String: Any] = [
            "id": 42, "name": "ecRecover", "provider": "ethereum",
            "host": "wallet.example", "configurationKey": origin,
            "authority": initial.version.json,
            "enqueueAttempt": String(repeating: "2", count: 32),
            "admissionDeadline": Int(Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000),
            "workflowVersion": ExtensionBridge.workflowVersion,
            "body": ["address": "", "chainId": "0x1", "object": [
                "signature": signature,
                "message": WalletCrypto.hexString(data: message).withHexPrefix,
            ]],
        ]
        let request = try XCTUnwrap(SafariRequest(json: object))
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(request: request, rawObject: object),
              case .accepted(let handle, _, _, _, _) = await bridge.enqueue(
                ingress: ingress, profileIdentifier: nil
              ) else { return XCTFail("Permission-free recovery must admit the original snapshot") }
        let admission = DappRequestAdmission(store: bridge, requestProcessor: DappRequestProcessor())
        let disposition = await admission.materialize(handle: handle)
        XCTAssertEqual(disposition, .responseReady)
        guard case .response(let envelope) = await bridge.prepareResponseDelivery(
            id: handle.id, configurationKey: origin,
            requestToken: handle.requestToken, profileIdentifier: nil
        ) else { return XCTFail("Expected completed recovery") }
        let terminal = try XCTUnwrap(envelope["response"] as? [String: Any])
        let expectedAddress = WalletCrypto.addressFromPublicKeyData(key.publicKeyData(coin: .ethereum), coin: .ethereum)
        XCTAssertEqual((terminal["result"] as? String)?.lowercased(), expectedAddress.lowercased())
        let state = try XCTUnwrap(envelope["state"] as? [String: Any])
        XCTAssertEqual((state["ethereum"] as? [String: String])?["address"], "")
    }
}
