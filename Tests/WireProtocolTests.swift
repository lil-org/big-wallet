import Foundation
import XCTest
@testable import Big_Wallet

final class WireProtocolTests: XCTestCase {
    private struct DecodedObject: Decodable {
        static let contractKey = CodingUserInfoKey(rawValue: "wireContract")!
        let value: WireProtocol.ValidatedObject

        init(from decoder: Decoder) throws {
            guard let contract = decoder.userInfo[Self.contractKey] as? WireProtocol.Message else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "Missing test contract"
                ))
            }
            value = try WireProtocol.object(contract, from: decoder)
        }
    }

    private struct Fixture {
        let name: String
        let message: WireProtocol.Message
        let valid: Bool
        let value: Any
    }

    private func fixtures() throws -> [Fixture] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Safari Shared/Tests/fixtures/wire_protocol_contract.json")
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        return try values.map { value in
            let name = try XCTUnwrap(value["name"] as? String)
            let type = try XCTUnwrap(value["type"] as? String, name)
            return Fixture(
                name: name,
                message: try XCTUnwrap(WireProtocol.Message(rawValue: type), name),
                valid: try XCTUnwrap(value["valid"] as? Bool, name),
                value: try XCTUnwrap(value["value"], name)
            )
        }
    }

    func testIndependentContractFixturesMatchJavaScript() throws {
        for fixture in try fixtures() {
            let decoded = WireProtocol.decode(fixture.message, value: fixture.value)
            XCTAssertEqual(decoded != nil, fixture.valid, fixture.name)
            XCTAssertEqual(WireProtocol.validate(fixture.message, value: fixture.value), fixture.valid, fixture.name)
            let object = WireProtocol.object(fixture.message, value: fixture.value)
            XCTAssertEqual(object != nil, fixture.valid && fixture.value is [String: Any], fixture.name)
            if let object {
                XCTAssertEqual(object.contract, fixture.message, fixture.name)
            }
            if let decoded, fixture.valid {
                let expected = try JSONSerialization.data(withJSONObject: fixture.value, options: [.fragmentsAllowed, .sortedKeys])
                let actual = try JSONSerialization.data(withJSONObject: decoded, options: [.fragmentsAllowed, .sortedKeys])
                XCTAssertEqual(actual, expected, fixture.name)
            }
        }
    }

    func testEveryContractHasAnIndependentPositiveExample() throws {
        let covered = Set(try fixtures().filter(\.valid).map(\.message))
        XCTAssertEqual(covered, Set(WireProtocol.Message.allCases))
    }

    func testValidatedObjectDetachesMutableFoundationContainers() throws {
        let item = NSMutableDictionary(dictionary: ["value": "original"])
        let items = NSMutableArray(object: item)
        let source = NSMutableDictionary(dictionary: ["id": 91, "result": ["items": items]])
        let object = try XCTUnwrap(WireProtocol.object(.rpcResponse, value: source))

        source["id"] = 92
        item["value"] = "changed"
        items.add("later")

        XCTAssertEqual(object.contract, .rpcResponse)
        XCTAssertEqual(object.json["id"] as? Int, 91)
        let result = try XCTUnwrap(object.json["result"] as? [String: Any])
        XCTAssertEqual(result["items"] as? [[String: String]], [["value": "original"]])
    }

    func testEveryNativeCommandFixtureAdaptsToItsDomainRequest() throws {
        for fixture in try fixtures() where fixture.message == .nativeCommand {
            let data = try JSONSerialization.data(withJSONObject: fixture.value)
            if !fixture.valid {
                XCTAssertThrowsError(try JSONDecoder().decode(InternalSafariRequest.self, from: data), fixture.name)
                continue
            }
            let request = try JSONDecoder().decode(InternalSafariRequest.self, from: data)
            let json = try XCTUnwrap(fixture.value as? [String: Any])
            XCTAssertEqual(request.id, json["id"] as? Int, fixture.name)
            XCTAssertEqual(request.workflowVersion, WireProtocol.workflowVersion, fixture.name)
            let wire = try Self.decodeObject(.nativeCommand, from: data)
            XCTAssertEqual(wire.json as NSDictionary, json as NSDictionary, fixture.name)
            let roundTrip = try Self.decodeObject(.nativeCommand, from: canonicalJSON(wire.json))
            XCTAssertEqual(roundTrip.json as NSDictionary, json as NSDictionary, fixture.name)
        }
    }

    func testApprovalMappingPreservesSelectionAndAbsentOptionals() throws {
        let accounts: [[String: Any]] = [
            ["walletId": "first", "address": "0xABcd", "coin": "ethereum", "derivationPath": "m/44'/60'/0'/0/1"],
            ["walletId": "second", "address": "CaseSensitive", "coin": "solana", "derivationPath": "m/44'/501'/0'/0'"],
        ]
        let body: [String: Any] = ["selectedAccounts": accounts, "chainId": "0xA", "cluster": "devnet"]
        guard case .popup(.approveRequest(_, let payload)) = try popupCommand("approveRequest", payload: body).command else {
            return XCTFail("Expected approval")
        }
        let mapped = try XCTUnwrap(payload.selectedAccounts)
        XCTAssertEqual(mapped.map(\.walletId), ["first", "second"])
        XCTAssertEqual(mapped.map(\.address), ["0xABcd", "CaseSensitive"])
        XCTAssertEqual(mapped.map(\.coin), [.ethereum, .solana])
        XCTAssertEqual(mapped.map(\.derivationPath), accounts.compactMap { $0["derivationPath"] as? String })
        XCTAssertEqual(payload.chainId, "0xA")
        XCTAssertEqual(payload.cluster, .devnet)

        for body: [String: Any] in [[:], ["selectedAccounts": []]] {
            guard case .popup(.approveRequest(_, let empty)) = try popupCommand("approveRequest", payload: body).command else {
                return XCTFail("Expected approval")
            }
            XCTAssertEqual(empty.selectedAccounts?.count, body["selectedAccounts"] == nil ? nil : 0)
            XCTAssertNil(empty.chainId)
            XCTAssertNil(empty.cluster)
        }
    }

    func testTransactionPayloadMappingPreservesNumbersAndEnums() throws {
        for (interaction, value): (String, Any) in [("cancelled", 200), ("ended", 137.5)] {
            let body: [String: Any] = ["interaction": interaction, "value": value]
            guard case .popup(.setTransactionSpeed(_, let payload)) = try popupCommand("setTransactionSpeed", payload: body).command else {
                return XCTFail("Expected speed change")
            }
            XCTAssertEqual(payload.interaction.rawValue, interaction)
            XCTAssertEqual(payload.value, (value as? NSNumber)?.doubleValue)
        }
        let custom: [String: Any] = [
            "mode": "custom", "nonce": "001", "maxPriorityFeePerGasGwei": "0.123456789",
            "maxFeePerGasGwei": "2.000000001",
        ]
        guard case .popup(.applyTransactionEdits(_, .custom(let edits))) = try popupCommand("applyTransactionEdits", payload: custom).command,
              case .popup(.applyTransactionEdits(_, .suggested)) = try popupCommand("applyTransactionEdits", payload: ["mode": "suggested"]).command,
              case .popup(.resolveApprovalAlert(_, let alert)) = try popupCommand("resolveApprovalAlert", payload: ["action": "edit"]).command else {
            return XCTFail("Expected mapped transaction commands")
        }
        XCTAssertEqual(edits.nonce, "001")
        XCTAssertEqual(edits.maxPriorityFeePerGasGwei, "0.123456789")
        XCTAssertEqual(edits.maxFeePerGasGwei, "2.000000001")
        XCTAssertNil(edits.gasPriceGwei)
        XCTAssertEqual(alert.action, .edit)
    }

    func testAuthorityMappingRetainsIntegerBoundsAcrossEntryPoints() throws {
        let revisions: [String: Any] = ["ethereum": 0, "solana": 9_007_199_254_740_991]
        let authority: [String: Any] = ["context": String(repeating: "a", count: 64), "revisions": revisions]
        let command: [String: Any] = [
            "id": 1, "workflowVersion": WireProtocol.workflowVersion, "subject": "disconnect",
            "configurationKey": "https://wallet.example", "provider": "solana",
            "attempt": String(repeating: "b", count: 32), "authority": authority,
        ]
        guard case .page(.disconnect(let disconnect)) = try decodeJSON(InternalSafariRequest.self, command).command else {
            return XCTFail("Expected disconnect")
        }
        let decoded = try decodeJSON(ExtensionBridge.AuthorityVersion.self, authority)
        let raw = try XCTUnwrap(ExtensionBridge.AuthorityVersion(rawValue: authority))
        XCTAssertEqual(disconnect.provider, .solana)
        XCTAssertEqual(disconnect.authority, decoded)
        XCTAssertEqual(raw, decoded)
        XCTAssertEqual(decoded.context, authority["context"] as? String)
        XCTAssertEqual(decoded.revisions.ethereum, 0)
        XCTAssertEqual(decoded.revisions.solana, 9_007_199_254_740_991)
        XCTAssertEqual(try decodeJSON(ExtensionBridge.ProviderRevisions.self, revisions), decoded.revisions)
        XCTAssertEqual(ExtensionBridge.ProviderRevisions(rawValue: revisions), decoded.revisions)

        for invalid: Any in [true, -1, 1.5, 9_007_199_254_740_992] {
            let invalidRevisions: [String: Any] = ["ethereum": invalid, "solana": 0]
            let invalidAuthority: [String: Any] = ["context": authority["context"]!, "revisions": invalidRevisions]
            var invalidCommand = command
            invalidCommand["authority"] = invalidAuthority
            XCTAssertThrowsError(try decodeJSON(InternalSafariRequest.self, invalidCommand))
            XCTAssertThrowsError(try decodeJSON(ExtensionBridge.AuthorityVersion.self, invalidAuthority))
            XCTAssertThrowsError(try decodeJSON(ExtensionBridge.ProviderRevisions.self, invalidRevisions))
            XCTAssertNil(ExtensionBridge.AuthorityVersion(rawValue: invalidAuthority))
            XCTAssertNil(ExtensionBridge.ProviderRevisions(rawValue: invalidRevisions))
        }
    }

    func testStandalonePayloadDecodersRetainTheirStrictBoundaries() throws {
        let allFixtures = try fixtures()
        func check<Value: Decodable>(_ type: Value.Type, message: WireProtocol.Message, invalid: [[String: Any]] = []) throws {
            for fixture in allFixtures where fixture.message == message {
                if fixture.valid {
                    XCTAssertNoThrow(try decodeJSON(type, fixture.value), fixture.name)
                    var extra = try XCTUnwrap(fixture.value as? [String: Any])
                    extra["unexpected"] = true
                    XCTAssertThrowsError(try decodeJSON(type, extra), fixture.name)
                } else {
                    XCTAssertThrowsError(try decodeJSON(type, fixture.value), fixture.name)
                }
            }
            for value in invalid { XCTAssertThrowsError(try decodeJSON(type, value), message.rawValue) }
        }
        try check(InternalSafariRequest.SelectedAccount.self, message: .selectedAccount)
        try check(InternalSafariRequest.ApprovalPayload.self, message: .approvalPayload, invalid: [["cluster": "mainnet"]])
        try check(InternalSafariRequest.TransactionSpeedPayload.self, message: .transactionSpeedPayload, invalid: [
            ["interaction": "ended", "value": true], ["interaction": "ended", "value": NSNull()],
            ["interaction": "unknown", "value": 100],
        ])
        try check(InternalSafariRequest.TransactionEditsPayload.self, message: .transactionEditsPayload, invalid: [["mode": "unknown"]])
        try check(InternalSafariRequest.ApprovalAlertPayload.self, message: .approvalAlertPayload, invalid: [["action": "unknown"]])
        try check(ExtensionBridge.ProviderRevisions.self, message: .revisions)
        try check(ExtensionBridge.AuthorityVersion.self, message: .authorityVersion)
    }

    func testEveryDappFixtureAdaptsWithoutLosingOpaquePayloads() throws {
        for fixture in try fixtures() where fixture.message == .dappRequest && fixture.valid {
            let json = try XCTUnwrap(fixture.value as? [String: Any])
            let wire = try XCTUnwrap(WireProtocol.object(.dappRequest, value: json), fixture.name)
            let request = try XCTUnwrap(SafariRequest(wire: wire), fixture.name)
            XCTAssertEqual(request.id, json["id"] as? Int, fixture.name)
            XCTAssertEqual(request.name, json["name"] as? String, fixture.name)
            XCTAssertEqual(wire.json as NSDictionary, json as NSDictionary, fixture.name)
        }
    }

    func testValidatedObjectsRetainStrictDecoding() throws {
        let command: [String: Any] = [
            "id": 1, "workflowVersion": WireProtocol.workflowVersion, "subject": "getRecoveryRequests",
        ]
        for field in ["profileIdentifier", "authority", "unexpected"] {
            var invalid = command
            invalid[field] = "untrusted"
            let data = try JSONSerialization.data(withJSONObject: invalid)
            XCTAssertThrowsError(try Self.decodeObject(.nativeCommand, from: data), field)
            XCTAssertThrowsError(try JSONDecoder().decode(InternalSafariRequest.self, from: data), field)
        }
    }

    func testOpaqueRPCNumbersSurviveNativeAndDecoderAdapters() throws {
        for literal in [
            "0.023359359010151733", "0.00033461068556032595", "0.1234567890123456789",
            "5e-324", "1e-300", "1e300", "1.7976931348623157e308",
        ] {
            for payload in [literal, "{\"nested\":[\(literal),{\"value\":\(literal)}]}"] {
                for field in ["\"result\":\(payload)", "\"error\":{\"code\":-32603,\"message\":\"Upstream error\",\"data\":\(payload)}"] {
                    let data = Data("{\"id\":91,\"jsonrpc\":\"2.0\",\(field)}".utf8)
                    let source = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let expected = try canonicalJSON(source)
                    let wire = try XCTUnwrap(WireProtocol.object(.rpcResponse, value: source), literal)
                    let relay = try XCTUnwrap(RPCResponseToExtension(upstream: source, expectedResponseID: 91), literal)
                    let decoded = try Self.decodeObject(.rpcResponse, from: data)
                    for value in [wire.json, relay.json, decoded.json] {
                        XCTAssertEqual(try canonicalJSON(value), expected, field)
                    }
                }
            }
        }
    }

    func testPropertyListDecimalObjectsRemainObjects() throws {
        let decimalData = try PropertyListEncoder().encode(Decimal(1))
        let decimalObject = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: decimalData, format: nil) as? [String: Any]
        )
        for extraFields in [false, true] {
            var object = decimalObject
            if extraFields { object["unexpected"] = ["grants": "ignored"] }
            let revisions: [String: Any] = ["ethereum": object, "solana": 0]
            let data = try PropertyListSerialization.data(fromPropertyList: revisions, format: .binary, options: 0)
            XCTAssertFalse(WireProtocol.validate(.revisions, value: revisions))
            XCTAssertNil(WireProtocol.object(.revisions, value: revisions))
            XCTAssertThrowsError(try PropertyListDecoder().decode(ExtensionBridge.ProviderRevisions.self, from: data))

            let response: [String: Any] = ["id": 1, "result": object]
            let decoded = try XCTUnwrap(WireProtocol.object(.rpcResponse, value: response))
            XCTAssertEqual(try canonicalJSON(decoded.json), try canonicalJSON(response))
        }
    }

    func testRPCContainerDepthLimitIncludesTheEnvelope() throws {
        XCTAssertEqual(WireProtocol.maximumJSONDepth, 64)
        let limit = WireProtocol.maximumJSONDepth(for: .rpcResponse)
        XCTAssertEqual(limit, 63)
        XCTAssertEqual(WireProtocol.maximumJSONDepth(for: .nativeResponse), 63)
        XCTAssertEqual(WireProtocol.maximumJSONDepth(for: .pageResponse), 63)
        XCTAssertEqual(WireProtocol.maximumJSONDepth(for: .nativeDelivery), 64)
        XCTAssertEqual(WireProtocol.maximumJSONDepth(for: .contentToPage), 64)
        for arrays in [false, true] {
            for depth in [limit, limit + 1] {
                let opening = arrays ? "[" : "{\"value\":"
                let closing = arrays ? "]" : "}"
                let payload = String(repeating: opening, count: depth - 1) + "null" +
                    String(repeating: closing, count: depth - 1)
                let data = Data("{\"id\":91,\"result\":\(payload)}".utf8)
                let source = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let valid = depth <= limit
                XCTAssertEqual(WireProtocol.validate(.rpcResponse, value: source), valid)
                XCTAssertEqual(WireProtocol.decode(.rpcResponse, value: source) != nil, valid)
                XCTAssertEqual(WireProtocol.object(.rpcResponse, value: source) != nil, valid)
                XCTAssertEqual(RPCResponseToExtension(upstream: source, expectedResponseID: 91) != nil, valid)
                if valid {
                    let decoded = try Self.decodeObject(.rpcResponse, from: data)
                    XCTAssertEqual(try canonicalJSON(decoded.json), try canonicalJSON(source))
                } else {
                    XCTAssertThrowsError(try Self.decodeObject(.rpcResponse, from: data))
                }
            }
        }
    }

    func testDeepRPCResponseIsRejectedOnTaskExecutor() async throws {
        let rejected = try await Task.detached {
            let payload = String(repeating: "{\"value\":", count: 300) + "null" +
                String(repeating: "}", count: 300)
            let data = Data("{\"id\":91,\"result\":\(payload)}".utf8)
            let source = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return !WireProtocol.validate(.rpcResponse, value: source) &&
                WireProtocol.decode(.rpcResponse, value: source) == nil &&
                WireProtocol.object(.rpcResponse, value: source) == nil &&
                RPCResponseToExtension(upstream: source, expectedResponseID: 91) == nil &&
                (try? Self.decodeObject(.rpcResponse, from: data)) == nil
        }.value
        XCTAssertTrue(rejected)
    }

    private func canonicalJSON(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    private static func decodeObject(_ contract: WireProtocol.Message, from data: Data) throws -> WireProtocol.ValidatedObject {
        let decoder = JSONDecoder()
        decoder.userInfo[DecodedObject.contractKey] = contract
        return try decoder.decode(DecodedObject.self, from: data).value
    }

    private func decodeJSON<Value: Decodable>(_ type: Value.Type, _ value: Any) throws -> Value {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    private func popupCommand(_ subject: String, payload: [String: Any]) throws -> InternalSafariRequest {
        try decodeJSON(InternalSafariRequest.self, [
            "id": 1, "workflowVersion": WireProtocol.workflowVersion, "subject": subject,
            "requestToken": "00000000-0000-4000-8000-000000000001",
            "reviewToken": "00000000-0000-4000-8000-000000000002", "payload": payload,
        ])
    }
}
