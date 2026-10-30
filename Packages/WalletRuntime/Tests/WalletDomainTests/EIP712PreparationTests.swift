import Foundation
import XCTest
@testable import WalletDomain

final class EIP712PreparationTests: XCTestCase {
    private let shortBytesJSON = #"{"types":{"EIP712Domain":[],"Order":[{"name":"tag","type":"bytes4"}]},"primaryType":"Order","domain":{},"message":{"tag":"0xabc"}}"#
    private let emptyJSON = #"{"types":{"EIP712Domain":[],"Empty":[]},"primaryType":"Empty","domain":{},"message":{}}"#

    func testPreparedPayloadPreservesExactJSONAndReleasedDigest() throws {
        let raw = " \n" + shortBytesJSON + "\n "
        let prepared = try XCTUnwrap(PreparedEthereumTypedData(json: raw))
        XCTAssertEqual(prepared.rawJSON, raw)
        XCTAssertEqual(WalletEncoding.hexString(prepared.digest), "b972f221377cfab15ee3c98e70712b52d2fa022ce91eeb17c2cb347054a40dba")
        XCTAssertEqual(EIP712.digest(json: raw), prepared.digest)
        XCTAssertEqual(WalletEncoding.ethereumTypedDataDigest(messageJson: raw), prepared.digest)
        var exportedDigest = prepared.digest
        exportedDigest[0] ^= 0xff
        XCTAssertNotEqual(exportedDigest, prepared.digest)
        XCTAssertEqual(PreparedEthereumTypedData(json: raw), prepared)
    }

    func testInputUTF8ByteLimitIsInclusive() throws {
        let maximum = EIP712.Limits().inputBytes
        let base = String(emptyJSON.dropLast()) + #", "ignored":"é"}"#
        let boundary = base + String(repeating: " ", count: maximum - base.utf8.count)
        XCTAssertEqual(boundary.utf8.count, maximum)
        XCTAssertNotNil(PreparedEthereumTypedData(json: boundary))
        assertFailure(.inputTooLarge, json: boundary + " ")
    }

    func testRawJSONDepthLimitRunsBeforeFoundationDecoding() throws {
        func nested(_ depth: Int) -> String {
            String(emptyJSON.dropLast()) + #", "ignored":"# +
                String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth) + "}"
        }
        XCTAssertNotNil(PreparedEthereumTypedData(json: nested(63)))
        assertFailure(.jsonTooDeep, json: nested(64))
        let escaped = try json(fieldType: "string", value: String(repeating: #"[\"]}"#, count: 100))
        XCTAssertNotNil(PreparedEthereumTypedData(json: escaped))
    }

    func testRawJSONTokenLimitIncludesUnusedValues() throws {
        let prefix = String(emptyJSON.dropLast()) + #", "ignored":["#
        let values = String(repeating: "0,", count: 65_520) + "0"
        XCTAssertNotNil(PreparedEthereumTypedData(json: prefix + values + "]}"))
        assertFailure(.tooManyJSONTokens, json: prefix + values + ",0]}")
    }

    func testTypeCountLimitIsInclusive() throws {
        var types: [String: Any] = ["EIP712Domain": [], "Root": []]
        for index in 0..<254 { types["Unused\(index)"] = [] }
        XCTAssertNotNil(PreparedEthereumTypedData(json: try document(types: types, message: [:])))
        types["OneMore"] = []
        assertFailure(.tooManyTypes, json: try document(types: types, message: [:]))
    }

    func testPerTypeAndTotalFieldLimitsIncludeUnusedDeclarations() throws {
        let field = ["name": "value", "type": "uint8"]
        var types: [String: Any] = ["EIP712Domain": [], "Root": Array(repeating: field, count: 128)]
        XCTAssertNotNil(PreparedEthereumTypedData(json: try document(types: types, message: ["value": 1])))
        types["Root"] = Array(repeating: field, count: 129)
        assertFailure(.tooManyFields, json: try document(types: types, message: ["value": 1]))
        types["Root"] = Array(repeating: field, count: 128)
        for index in 0..<31 { types["Unused\(index)"] = Array(repeating: field, count: 128) }
        XCTAssertNotNil(PreparedEthereumTypedData(json: try document(types: types, message: ["value": 1])))
        types["Extra"] = [field]
        assertFailure(.tooManyFields, json: try document(types: types, message: ["value": 1]))
    }

    func testDependencyDepthCountsShallowJSONTypeChains() throws {
        func chain(_ count: Int) throws -> String {
            var types: [String: Any] = ["EIP712Domain": []]
            for index in 0..<count {
                types["T\(index)"] = index + 1 < count
                    ? [["name": "children", "type": "T\(index + 1)[]"]] : []
            }
            return try document(types: types, primaryType: "T0", message: ["children": []])
        }
        XCTAssertNotNil(PreparedEthereumTypedData(json: try chain(32)))
        assertFailure(.dependencyTooDeep, json: try chain(33))
    }

    func testValueDepthAndRecursiveArrayTermination() throws {
        var types: [String: Any] = ["EIP712Domain": []]
        for index in 0..<31 {
            types["T\(index)"] = [["name": "next", "type": "T\(index + 1)"]]
        }
        types["T31"] = [["name": "children", "type": "T31[]"]]
        func nested(_ terminal: [String: Any]) -> [String: Any] {
            var message = terminal
            for _ in 0..<31 { message = ["next": message] }
            return message
        }
        let boundary = try document(types: types, primaryType: "T0", message: nested(["children": []]))
        XCTAssertNotNil(PreparedEthereumTypedData(json: boundary))
        let tooDeep = try document(types: types, primaryType: "T0", message: nested(["children": [["children": []]]]))
        assertFailure(.valueTooDeep, json: tooDeep)
        let recursive = #"{"types":{"EIP712Domain":[],"Node":[{"name":"children","type":"Node[]"},{"name":"name","type":"string"}]},"primaryType":"Node","domain":{},"message":{"children":[],"name":"root"}}"#
        XCTAssertNotNil(PreparedEthereumTypedData(json: recursive))
    }

    func testArrayTypeDepthIsCheckedEvenForEmptyValues() throws {
        XCTAssertNotNil(PreparedEthereumTypedData(json: try json(fieldType: "uint256" + String(repeating: "[]", count: 32), value: [])))
        assertFailure(.arrayTypeTooDeep, json: try json(fieldType: "uint256" + String(repeating: "[]", count: 33), value: []))
    }

    func testArrayElementLimitIsInclusive() throws {
        XCTAssertNotNil(PreparedEthereumTypedData(json: try json(fieldType: "uint8[]", value: Array(repeating: 1, count: 4_096))))
        assertFailure(.arrayTooLarge, json: try json(fieldType: "uint8[]", value: Array(repeating: 1, count: 4_097)))
    }

    func testRepeatedFieldExpansionConsumesAggregateWork() throws {
        func expanded(_ depth: Int) throws -> String {
            var types: [String: Any] = ["EIP712Domain": [], "T\(depth)": []]
            var message = [String: Any]()
            for index in (0..<depth).reversed() {
                let field = ["name": "child", "type": "T\(index + 1)"]
                types["T\(index)"] = [field, field]
                message = ["child": message]
            }
            return try document(types: types, primaryType: "T0", message: message)
        }
        XCTAssertNotNil(PreparedEthereumTypedData(json: try expanded(13)))
        assertFailure(.tooMuchWork, json: try expanded(14))
    }

    func testRepeatedLargeValuesConsumeAggregateBytes() throws {
        let fields = Array(repeating: ["name": "value", "type": "string"], count: 128)
        let types: [String: Any] = ["EIP712Domain": [], "Root": fields]
        XCTAssertNotNil(PreparedEthereumTypedData(json: try document(types: types, message: ["value": String(repeating: "x", count: 20_000)])))
        assertFailure(.tooManyProcessingBytes, json: try document(types: types, message: ["value": String(repeating: "x", count: 40_000)]))
    }

    func testIntegerConversionRejectsLargeMagnitudesAndPreservesLeadingZeros() throws {
        let one = try json(fieldType: "uint256", value: "1")
        let decimal = try json(fieldType: "uint256", value: String(repeating: "0", count: 200_000) + "1")
        let hexadecimal = try json(fieldType: "uint256", value: "0x" + String(repeating: "0", count: 200_000) + "1")
        XCTAssertEqual(EIP712.digest(json: decimal), EIP712.digest(json: one))
        XCTAssertEqual(EIP712.digest(json: hexadecimal), EIP712.digest(json: one))
        assertFailure(.invalid, json: try json(fieldType: "uint256", value: String(repeating: "9", count: 200_000)))
        assertFailure(.invalid, json: try json(fieldType: "uint256", value: "0x1" + String(repeating: "0", count: 64)))
        XCTAssertNotNil(PreparedEthereumTypedData(json: try json(fieldType: "uint256", value: "0x" + String(repeating: "f", count: 64))))
        XCTAssertNotNil(PreparedEthereumTypedData(json: try json(fieldType: "uint256", value: "115792089237316195423570985008687907853269984665640564039457584007913129639935")))
        assertFailure(.invalid, json: try json(fieldType: "uint256", value: "115792089237316195423570985008687907853269984665640564039457584007913129639936"))
        XCTAssertEqual(EIP712.digest(json: try json(fieldType: "int256", value: "-0000")), EIP712.digest(json: try json(fieldType: "int256", value: "0")))
        XCTAssertNotNil(PreparedEthereumTypedData(json: try json(fieldType: "int256", value: "-57896044618658097711785492504343953926634992332820282019728792003956564819968")))
        assertFailure(.invalid, json: try json(fieldType: "int256", value: "-0x01"))
    }

    func testCancellationRejectsPreparationAndDigestHelpers() async {
        let raw = shortBytesJSON
        let outcome = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            let cancelled: Bool
            do {
                _ = try EIP712.checkedDigest(json: raw)
                cancelled = false
            } catch is CancellationError {
                cancelled = true
            } catch {
                cancelled = false
            }
            return cancelled && PreparedEthereumTypedData(json: raw) == nil && EIP712.digest(json: raw).isEmpty
        }.value
        XCTAssertTrue(outcome)
    }

    func testBudgetAcceptanceDoesNotDependOnTypeDictionaryOrder() throws {
        let order = ["Zebra", "Alpha", "Delta", "Beta", "Gamma"]
        let fields = order.map { ["name": $0, "type": $0] }
        let root = #""Root":"# + String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
        let entries = order.map { #""\#($0)":[{"name":"n","type":"uint8"}]"# }
        let message = Dictionary(uniqueKeysWithValues: order.map { ($0, ["n": 1]) })
        let messageJSON = String(decoding: try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]), as: UTF8.self)
        func raw(_ definitions: [String]) -> String {
            #"{"types":{"EIP712Domain":[],"# + ([root] + definitions).joined(separator: ",") +
                #"},"primaryType":"Root","domain":{},"message":"# + messageJSON + "}"
        }
        let first = raw(entries)
        let second = raw(Array(entries.reversed()))
        XCTAssertNotNil(PreparedEthereumTypedData(json: first))
        var lower = 0
        var upper = EIP712.Limits().processingBytes
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            var limits = EIP712.Limits()
            limits.processingBytes = middle
            if (try? EIP712.checkedDigest(json: first, limits: limits)) == nil { lower = middle + 1 }
            else { upper = middle }
        }
        for limit in [lower - 1, lower, lower + 1] {
            var limits = EIP712.Limits()
            limits.processingBytes = limit
            XCTAssertEqual(try? EIP712.checkedDigest(json: first, limits: limits), try? EIP712.checkedDigest(json: second, limits: limits))
        }
    }

    func testTypeCachesPreserveCanonicalEquivalentUTF8Spellings() throws {
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        let scalar = Data(repeating: 0, count: 31) + Data([1])
        let domain = WalletEncoding.keccak256(data: WalletEncoding.keccak256(data: Data("EIP712Domain()".utf8)))
        func structHash(_ name: String) -> Data {
            let type = WalletEncoding.keccak256(data: Data("\(name)(uint8 n)".utf8))
            return WalletEncoding.keccak256(parts: [type, scalar])
        }
        for spellings in [[composed, decomposed], [decomposed, composed]] {
            let fields = [["name": "first", "type": spellings[0]], ["name": "second", "type": spellings[1]]]
            let types: [String: Any] = ["EIP712Domain": [], "Root": fields, composed: [["name": "n", "type": "uint8"]]]
            let raw = try document(types: types, message: ["first": ["n": 1], "second": ["n": 1]])
            let typeText = "Root(\(spellings[0]) first,\(spellings[1]) second)\(spellings[0])(uint8 n)"
            let root = WalletEncoding.keccak256(parts: [
                WalletEncoding.keccak256(data: Data(typeText.utf8)),
                structHash(spellings[0]), structHash(spellings[1]),
            ])
            let expected = WalletEncoding.keccak256(parts: [Data([0x19, 0x01]), domain, root])
            XCTAssertEqual(PreparedEthereumTypedData(json: raw)?.digest, expected)
        }
        var types: [String: Any] = [
            "EIP712Domain": [], "Root": [["name": "child", "type": decomposed]],
            composed: [["name": "n", "type": "uint8"]],
        ]
        let original = try document(types: types, message: ["child": ["n": 1]])
        types["Unused"] = [["name": "other", "type": composed]]
        let extraDeclaration = try document(types: types, message: ["child": ["n": 1]])
        XCTAssertEqual(PreparedEthereumTypedData(json: original)?.digest, PreparedEthereumTypedData(json: extraDeclaration)?.digest)
    }

    func testSeededMalformedMutationsHaveDeterministicOutcomes() throws {
        var random: UInt64 = 0x7261_772d_7465_7374
        func next() -> UInt64 {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return random
        }
        let valid = try json(fieldType: "uint8[]", value: [1, 2, 3])
        let original = Array(valid.utf8)
        let expected = try XCTUnwrap(PreparedEthereumTypedData(json: valid)).digest
        for _ in 0..<256 {
            var bytes = original
            let index = Int(next() % UInt64(bytes.count))
            switch next() % 3 {
            case 0: bytes.removeSubrange(index..<bytes.count)
            case 1: bytes[index] = UInt8(next() % 128)
            default: bytes.insert(contentsOf: [91, 123, 34, 92], at: index)
            }
            let mutation = String(decoding: bytes, as: UTF8.self)
            let first = PreparedEthereumTypedData(json: mutation)
            XCTAssertEqual(first, PreparedEthereumTypedData(json: mutation))
            XCTAssertEqual(first?.digest ?? Data(), EIP712.digest(json: mutation))
            if let first { XCTAssertEqual(first.digest.count, 32) }
        }
        XCTAssertEqual(PreparedEthereumTypedData(json: valid)?.digest, expected)
    }

    private func json(fieldType: String, value: Any) throws -> String {
        try document(types: ["EIP712Domain": [], "Root": [["name": "value", "type": fieldType]]], message: ["value": value])
    }

    private func document(types: [String: Any], primaryType: String = "Root", message: [String: Any]) throws -> String {
        let value: [String: Any] = ["types": types, "primaryType": primaryType, "domain": [String: Any](), "message": message]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private func assertFailure(_ expected: EIP712.PreparationError, json: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EIP712.checkedDigest(json: json), file: file, line: line) {
            XCTAssertEqual($0 as? EIP712.PreparationError, expected, file: file, line: line)
        }
        XCTAssertNil(PreparedEthereumTypedData(json: json), file: file, line: line)
        XCTAssertTrue(EIP712.digest(json: json).isEmpty, file: file, line: line)
    }
}
