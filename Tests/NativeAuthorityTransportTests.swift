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
            "attemptID": requestToken,
            "executionDeadline": 9_000_000_000_000,
            "revisions": ["ethereum": 2, "solana": 3],
        ]))
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
