import Foundation
import XCTest
@testable import WalletNetworking

final class NativeRPCResponseDecoderTests: XCTestCase {
    func testValidResultsRequireMatchingNumericIDs() throws {
        for id in ["1", "1.0", "1e0", "10e-1", "0.1e1", "1." + String(repeating: "0", count: 80)] {
            let response = decode("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\"accepted\"}")
            XCTAssertEqual(response?.result, "accepted", id)
            XCTAssertNil(response?.error, id)
        }
        let otherID = #"{"jsonrpc":"2.0","id":7,"result":"accepted"}"#
        XCTAssertNil(decode(otherID))
        XCTAssertEqual(decode(otherID, expectedID: 7)?.result, "accepted")
        for (id, expected) in [("0", 0), ("-0.0e1000", 0), (String(Int.min), Int.min), (String(Int.max), Int.max)] {
            let body = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\"accepted\"}"
            XCTAssertEqual(decode(body, expectedID: expected)?.result, "accepted", id)
        }
        let escaped = #"{"jsonrpc":"2.0","\u0069d":1,"result":"numbers 1.0000000000000001 \"401\" \\ 1e0","metadata":{"id":1.5,"code":401.5}}"#
        XCTAssertEqual(decode(escaped)?.result, #"numbers 1.0000000000000001 "401" \ 1e0"#)
        for (encoding, bom) in Self.jsonEncodings {
            let body = try XCTUnwrap(escaped.data(using: encoding))
            for data in [body, Data(bom) + body] {
                let foundationResult = try? JSONDecoder().decode(Response.self, from: data).result
                XCTAssertEqual(NativeRPCResponseDecoder.decode(
                    Response.self, from: data, expectedID: 1
                )?.result, foundationResult, "Encoding: \(encoding)")
            }
        }
    }

    func testRejectsMissingOrInvalidVersionsAndIDs() throws {
        let bodies = [
            #"{"id":1,"result":"accepted"}"#,
            #"{"jsonrpc":null,"id":1,"result":"accepted"}"#,
            #"{"jsonrpc":2,"id":1,"result":"accepted"}"#,
            #"{"jsonrpc":"1.0","id":1,"result":"accepted"}"#,
            #"{"jsonrpc":"2.0 ","id":1,"result":"accepted"}"#,
            #"{"jsonrpc":"2.0","result":"accepted"}"#,
            #"{"jsonrpc":"2.0","id":null,"result":"accepted"}"#,
            #"{"jsonrpc":"2.0","id":"1","result":"accepted"}"#,
            #"{"jsonrpc":"2.0","id":true,"result":"accepted"}"#,
            #"{"jsonrpc":"2.0","id":false,"result":"accepted"}"#,
            #"{"jsonrpc":"2.0","id":1.5,"result":"accepted"}"#,
            #"{"jsonrpc":"2.0","id":[],"result":"accepted"}"#,
            #"{"jsonrpc":"2.0","id":{},"result":"accepted"}"#,
        ]
        for body in bodies { XCTAssertNil(decode(body), body) }
        for id in [
            "1.0000000000000001", "0.99999999999999999", "10000000000000001e-16",
            "1." + String(repeating: "0", count: 80) + "1", "1e-999999999999999999999999",
        ] {
            let body = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\"accepted\"}"
            XCTAssertNil(decode(body), body)
        }
        XCTAssertNil(decode(#"{"jsonrpc":"2.0","\u0069d":1.0000000000000001,"result":"accepted"}"#))
        for (encoding, bom) in Self.jsonEncodings {
            let body = try XCTUnwrap(#"{"jsonrpc":"2.0","id":1.0000000000000001,"result":"accepted"}"#.data(using: encoding))
            for data in [body, Data(bom) + body] {
                XCTAssertNil(NativeRPCResponseDecoder.decode(Response.self, from: data, expectedID: 1), "Encoding: \(encoding)")
            }
        }
    }

    func testRejectsBothOrNeitherPayloadFieldsIncludingNullMembers() {
        let bodies = [
            #"{"jsonrpc":"2.0","id":1}"#,
            #"{"jsonrpc":"2.0","id":1,"result":"accepted","error":{"code":1,"message":"failed"}}"#,
            #"{"jsonrpc":"2.0","id":1,"result":"accepted","error":null}"#,
            #"{"jsonrpc":"2.0","id":1,"result":null,"error":{"code":1,"message":"failed"}}"#,
            #"{"jsonrpc":"2.0","id":1,"result":null,"error":null}"#,
        ]
        for body in bodies { XCTAssertNil(decode(body), body) }
    }

    func testRejectsNullOrIncorrectlyTypedResults() {
        for result in ["null", "true", "42", "{}", "[]"] {
            let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(result)}"
            XCTAssertNil(decode(body), body)
        }
    }

    func testRejectsMalformedErrorsEvenWhenPayloadDecoderIsPermissive() throws {
        let errors = [
            "null", "[]", #""unauthorized""#, "{}",
            #"{"code":1}"#,
            #"{"message":"failed"}"#,
            #"{"code":null,"message":"failed"}"#,
            #"{"code":true,"message":"failed"}"#,
            #"{"code":"1","message":"failed"}"#,
            #"{"code":1.5,"message":"failed"}"#,
            #"{"code":1,"message":null}"#,
            #"{"code":1,"message":42}"#,
        ]
        for error in errors {
            let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":\(error)}"
            XCTAssertNil(decode(body), body)
        }
        for code in [
            "401.00000000000001", "-32602.000000000001", "40100000000000001e-14",
            "401." + String(repeating: "0", count: 80) + "1", "1e999999999999999999999999",
        ] {
            let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\(code),\"message\":\"failed\"}}"
            XCTAssertNil(decode(body), body)
        }
        XCTAssertNil(decode(#"{"jsonrpc":"2.0","id":1,"error":{"\u0063ode":401.00000000000001,"message":"failed"}}"#))
        for (encoding, bom) in Self.jsonEncodings {
            let body = try XCTUnwrap(#"{"jsonrpc":"2.0","id":1,"error":{"code":401.00000000000001,"message":"failed"}}"#.data(using: encoding))
            for data in [body, Data(bom) + body] {
                XCTAssertNil(NativeRPCResponseDecoder.decode(Response.self, from: data, expectedID: 1), "Encoding: \(encoding)")
            }
        }
    }

    func testValidErrorPreservesCodeMessageAndData() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"invalid params","data":{"reason":"invalid address"}},"extra":true}"#
        let response = try XCTUnwrap(decode(body))
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, -32602)
        XCTAssertEqual(response.error?.message, "invalid params")
        XCTAssertEqual(response.error?.data, ["reason": "invalid address"])
        for (code, expected) in [
            ("-0.0", 0), ("401.0", 401), ("4.01e2", 401), ("-32602e0", -32602),
            (String(Int.min), Int.min), (String(Int.max), Int.max),
        ] {
            let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\(code),\"message\":\"failed\"}}"
            XCTAssertEqual(decode(body)?.error?.code, expected, code)
        }
        XCTAssertEqual(decode(#"{"jsonrpc":"2.0","id":1,"error":{"\u0063ode":401,"message":"failed"}}"#)?.error?.code, 401)
    }

    func testNestedNullStatusRemainsAValidResult() throws {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"result":{"value":[null]}}"#.utf8)
        let response = try XCTUnwrap(NativeRPCResponseDecoder.decode(
            StatusResponse.self, from: body, expectedID: 1
        ))
        XCTAssertEqual(response.result.value.count, 1)
        XCTAssertNil(response.result.value[0])
        let fractionalResult = Data(#"{"jsonrpc":"2.0","id":1,"result":0.25}"#.utf8)
        XCTAssertEqual(NativeRPCResponseDecoder.decode(
            FractionalResponse.self, from: fractionalResult, expectedID: 1
        )?.result, 0.25)
    }

    func testRejectsNonObjectAndUnparseableResponses() {
        for body in ["null", "[]", "1", "true", #""reply""#, "{", "", "<html>Unauthorized</html>"] {
            XCTAssertNil(decode(body), body)
        }
    }

    private func decode(_ body: String, expectedID: Int = 1) -> Response? {
        NativeRPCResponseDecoder.decode(Response.self, from: Data(body.utf8), expectedID: expectedID)
    }

    private static let jsonEncodings: [(String.Encoding, [UInt8])] = [
        (.utf8, [0xef, 0xbb, 0xbf]),
        (.utf16LittleEndian, [0xff, 0xfe]),
        (.utf16BigEndian, [0xfe, 0xff]),
        (.utf32LittleEndian, [0xff, 0xfe, 0, 0]),
        (.utf32BigEndian, [0, 0, 0xfe, 0xff]),
    ]

    private struct Response: Decodable {
        let result: String?
        let error: Failure?
    }

    private struct Failure: Decodable {
        let code: Int?
        let message: String?
        let data: [String: String]?
    }

    private struct StatusResponse: Decodable {
        let result: StatusResult
    }

    private struct StatusResult: Decodable {
        let value: [String?]
    }

    private struct FractionalResponse: Decodable {
        let result: Double
    }
}
