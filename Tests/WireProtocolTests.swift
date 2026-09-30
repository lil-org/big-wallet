import Foundation
import XCTest
@testable import Big_Wallet

final class WireProtocolTests: XCTestCase {
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

    func testEveryNativeCommandFixtureAdaptsToItsDomainRequest() throws {
        for fixture in try fixtures() where fixture.message == .nativeCommand && fixture.valid {
            let data = try JSONSerialization.data(withJSONObject: fixture.value)
            let request = try JSONDecoder().decode(InternalSafariRequest.self, from: data)
            let json = try XCTUnwrap(fixture.value as? [String: Any])
            XCTAssertEqual(request.id, json["id"] as? Int, fixture.name)
            XCTAssertEqual(request.workflowVersion, WireProtocol.workflowVersion, fixture.name)
            let wire = try JSONDecoder().decode(WireProtocol.NativeCommand.self, from: data)
            XCTAssertEqual(wire.json as NSDictionary, json as NSDictionary, fixture.name)
            let roundTrip = try JSONDecoder().decode(
                WireProtocol.NativeCommand.self, from: JSONEncoder().encode(wire)
            )
            XCTAssertEqual(roundTrip.json as NSDictionary, json as NSDictionary, fixture.name)
        }
    }

    func testEveryDappFixtureAdaptsWithoutLosingOpaquePayloads() throws {
        for fixture in try fixtures() where fixture.message == .dappRequest && fixture.valid {
            let json = try XCTUnwrap(fixture.value as? [String: Any])
            let wire = try XCTUnwrap(WireProtocol.DappRequest(json: json), fixture.name)
            let request = try XCTUnwrap(SafariRequest(wire: wire), fixture.name)
            XCTAssertEqual(request.id, json["id"] as? Int, fixture.name)
            XCTAssertEqual(request.name, json["name"] as? String, fixture.name)
            XCTAssertEqual(wire.json as NSDictionary, json as NSDictionary, fixture.name)
        }
    }

    func testGeneratedDTOsRetainStrictDecoding() throws {
        let command: [String: Any] = [
            "id": 1, "workflowVersion": WireProtocol.workflowVersion, "subject": "getRecoveryRequests",
        ]
        for field in ["profileIdentifier", "authority", "unexpected"] {
            var invalid = command
            invalid[field] = "untrusted"
            let data = try JSONSerialization.data(withJSONObject: invalid)
            XCTAssertThrowsError(try JSONDecoder().decode(WireProtocol.NativeCommand.self, from: data), field)
            XCTAssertThrowsError(try JSONDecoder().decode(InternalSafariRequest.self, from: data), field)
        }
    }

    func testOpaqueRPCNumbersSurviveNativeAndCodableAdapters() throws {
        for literal in [
            "0.023359359010151733", "0.00033461068556032595", "0.1234567890123456789",
            "5e-324", "1e-300", "1e300", "1.7976931348623157e308",
        ] {
            for payload in [literal, "{\"nested\":[\(literal),{\"value\":\(literal)}]}"] {
                for field in ["\"result\":\(payload)", "\"error\":{\"code\":-32603,\"message\":\"Upstream error\",\"data\":\(payload)}"] {
                    let data = Data("{\"id\":91,\"jsonrpc\":\"2.0\",\(field)}".utf8)
                    let source = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let expected = try canonicalJSON(source)
                    let wire = try XCTUnwrap(WireProtocol.RPCResponse(json: source), literal)
                    let relay = try XCTUnwrap(RPCResponseToExtension(upstream: source, expectedResponseID: 91), literal)
                    let decoded = try JSONDecoder().decode(WireProtocol.RPCResponse.self, from: data)
                    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
                    for value in [wire.json, relay.json, decoded.json, encoded] {
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
            XCTAssertThrowsError(try PropertyListDecoder().decode(WireProtocol.Revisions.self, from: data))
            XCTAssertThrowsError(try PropertyListDecoder().decode(ExtensionBridge.ProviderRevisions.self, from: data))

            let response: [String: Any] = ["id": 1, "result": object]
            let responseData = try PropertyListSerialization.data(fromPropertyList: response, format: .binary, options: 0)
            let decoded = try PropertyListDecoder().decode(WireProtocol.RPCResponse.self, from: responseData)
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
                XCTAssertEqual(WireProtocol.RPCResponse(json: source) != nil, valid)
                XCTAssertEqual(RPCResponseToExtension(upstream: source, expectedResponseID: 91) != nil, valid)
                if valid {
                    let decoded = try JSONDecoder().decode(WireProtocol.RPCResponse.self, from: data)
                    XCTAssertEqual(try canonicalJSON(decoded.json), try canonicalJSON(source))
                } else {
                    XCTAssertThrowsError(try JSONDecoder().decode(WireProtocol.RPCResponse.self, from: data))
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
                WireProtocol.RPCResponse(json: source) == nil &&
                RPCResponseToExtension(upstream: source, expectedResponseID: 91) == nil &&
                (try? JSONDecoder().decode(WireProtocol.RPCResponse.self, from: data)) == nil
        }.value
        XCTAssertTrue(rejected)
    }

    private func canonicalJSON(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }
}
