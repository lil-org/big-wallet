import Foundation
import Synchronization
import XCTest
@testable import WalletDomain

final class EthereumABIBudgetTests: XCTestCase {
    private let selector = Data([1, 2, 3, 4])

    func testFixedEmptyTupleArrayCannotExpandFromSelectorOnlyCalldata() throws {
        let abi = try definition(type: "tuple[1000000000]", components: [])
        XCTAssertNil(EthereumABI.decodeCall(data: selector, abi: abi))
        XCTAssertNil(WalletEncoding.decodeEthereumCall(data: selector, abi: abi))
    }

    func testDynamicEmptyTupleArrayCannotExpandFromItsLengthWord() throws {
        let abi = try definition(type: "tuple[]", components: [])
        XCTAssertNil(EthereumABI.decodeCall(data: selector + word(32) + word(1_000_000_000), abi: abi))
    }

    func testSmallEmptyTupleArraysRemainSupported() throws {
        for (type, data) in [
            ("tuple[2]", selector),
            ("tuple[]", selector + word(32) + word(2)),
        ] {
            let result = try XCTUnwrap(EthereumABI.decodeCall(data: data, abi: definition(type: type, components: [])))
            let values = try arrayValue(result)
            XCTAssertEqual(values.count, 2)
            XCTAssertTrue(values.allSatisfy { ($0 as? [Any])?.isEmpty == true })
        }
    }

    func testOrdinaryFixedAndDynamicArraysKeepTheirValues() throws {
        for (type, data) in [
            ("uint256[3]", selector + word(1) + word(2) + word(3)),
            ("uint256[]", selector + word(32) + word(3) + word(1) + word(2) + word(3)),
        ] {
            let result = try XCTUnwrap(EthereumABI.decodeCall(data: data, abi: definition(type: type)))
            XCTAssertEqual(try arrayValue(result) as? [String], ["1", "2", "3"])
        }
    }

    func testDecodedValueBudgetIncludesArrayContainersAndEveryTuple() throws {
        var limits = EthereumABI.Limits()
        limits.decodedValues = 8
        XCTAssertNoThrow(try EthereumABI.checkedDecodeCall(
            data: selector, abi: definition(type: "tuple[7]", components: []), limits: limits
        ))
        assertLimit(data: selector, abi: try definition(type: "tuple[8]", components: []), limits: limits)
        limits.decodedValues = 16
        XCTAssertNoThrow(try EthereumABI.checkedDecodeCall(
            data: selector, abi: definition(type: "tuple[3][3]", components: []), limits: limits
        ))
        assertLimit(data: selector, abi: try definition(type: "tuple[4][4]", components: []), limits: limits)
        XCTAssertNil(EthereumABI.decodeCall(data: selector, abi: try definition(type: "tuple[128][128]", components: [])))
    }

    func testRepeatedDynamicOffsetsConsumeTheAggregateValueBudget() throws {
        let small = aliasedNestedArrays(depth: 2)
        let decoded = try XCTUnwrap(EthereumABI.decodeCall(data: small, abi: definition(type: "uint256[][]")))
        XCTAssertEqual(try arrayValue(decoded) as? [[String]], [["7"], ["7"]])
        let depth = 15
        let amplified = aliasedNestedArrays(depth: depth)
        XCTAssertLessThan(amplified.count, 2_048)
        XCTAssertNil(EthereumABI.decodeCall(
            data: amplified, abi: try definition(type: "uint256" + String(repeating: "[]", count: depth))
        ))
    }

    func testAliasedStringsConsumeAggregateDecodedBytes() throws {
        let text = Data("abc".utf8)
        let data = aliasedStrings(count: 2, bytes: text)
        let abi = try definition(type: "string[2]")
        var limits = EthereumABI.Limits()
        limits.decodedStringBytes = 6
        let result = try EthereumABI.checkedDecodeCall(data: data, abi: abi, limits: limits)
        XCTAssertEqual(try arrayValue(result) as? [String], ["abc", "abc"])
        limits.decodedStringBytes = 5
        assertLimit(data: data, abi: abi, limits: limits)

        let amplified = aliasedStrings(count: 32, bytes: Data(repeating: 120, count: 40_000))
        XCTAssertLessThan(amplified.count, 45_000)
        XCTAssertNil(EthereumABI.decodeCall(data: amplified, abi: try definition(type: "string[32]")))
    }

    func testInvalidUTF8CountsReplacementBytesBeforeRetainingTheString() throws {
        let data = selector + word(32) + word(1) + Data([0xff])
        let abi = try definition(type: "string")
        var limits = EthereumABI.Limits()
        limits.decodedStringBytes = 3
        let result = try EthereumABI.checkedDecodeCall(data: data, abi: abi, limits: limits)
        XCTAssertEqual(try firstInput(result)["value"] as? String, "\u{fffd}")
        limits.decodedStringBytes = 2
        assertLimit(data: data, abi: abi, limits: limits)
    }

    func testFinalJSONBudgetCountsEscapingAndUTF8Exactly() throws {
        let bytes = Data("\u{00}\n\"\\漢🙂".utf8)
        let data = selector + word(32) + word(bytes.count) + bytes
        let abi = try definition(type: "string", name: "\u{01}\"漢")
        let result = try XCTUnwrap(EthereumABI.decodeCall(data: data, abi: abi))
        XCTAssertEqual(try firstInput(result)["value"] as? String, String(decoding: bytes, as: UTF8.self))
        var limits = EthereumABI.Limits()
        limits.outputBytes = result.utf8.count
        XCTAssertEqual(try EthereumABI.checkedDecodeCall(data: data, abi: abi, limits: limits), result)
        limits.outputBytes -= 1
        assertLimit(data: data, abi: abi, limits: limits)
    }

    func testRepeatedTupleMetadataCountsAgainstFinalJSONBudget() throws {
        let member: [String: Any] = ["name": String(repeating: "n", count: 128), "type": "uint8"]
        let abi = try definition(type: "tuple[8]", components: [member])
        let data = selector + (0..<8).reduce(into: Data()) { data, _ in data.append(word(1)) }
        let result = try XCTUnwrap(EthereumABI.decodeCall(data: data, abi: abi))
        XCTAssertGreaterThan(result.utf8.count, 1_024)
        var limits = EthereumABI.Limits()
        limits.decodedStringBytes = 8
        limits.outputBytes = 1_024
        assertLimit(data: data, abi: abi, limits: limits)
        limits.outputBytes = result.utf8.count
        XCTAssertEqual(try EthereumABI.checkedDecodeCall(data: data, abi: abi, limits: limits), result)
    }

    func testAggregateWorkLimitIsInclusive() throws {
        let data = aliasedNestedArrays(depth: 5)
        let abi = try definition(type: "uint256[][][][][]")
        let expected = try XCTUnwrap(EthereumABI.decodeCall(data: data, abi: abi))
        var lower = 0
        var upper = EthereumABI.Limits().work
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            var limits = EthereumABI.Limits()
            limits.work = middle
            if (try? EthereumABI.checkedDecodeCall(data: data, abi: abi, limits: limits)) == nil {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        XCTAssertGreaterThan(lower, 1)
        var limits = EthereumABI.Limits()
        limits.work = lower
        XCTAssertEqual(try EthereumABI.checkedDecodeCall(data: data, abi: abi, limits: limits), expected)
        limits.work -= 1
        assertLimit(data: data, abi: abi, limits: limits)
    }

    func testSchemaNodeAndArrayDepthLimitsAreInclusive() throws {
        let input: [String: Any] = ["name": "", "type": "uint8"]
        let boundary = try definition(inputs: Array(repeating: input, count: 1_024))
        let values = (0..<1_024).reduce(into: selector) { data, _ in data.append(word(1)) }
        XCTAssertNotNil(EthereumABI.decodeCall(data: values, abi: boundary))
        XCTAssertNil(EthereumABI.decodeCall(data: values + word(1), abi: try definition(inputs: Array(repeating: input, count: 1_025))))

        let type = "uint8" + String(repeating: "[1]", count: 32)
        let data = selector + word(7)
        XCTAssertNotNil(EthereumABI.decodeCall(data: data, abi: try definition(type: type)))
        XCTAssertNil(EthereumABI.decodeCall(data: data, abi: try definition(type: type + "[1]")))
        var limits = EthereumABI.Limits()
        limits.schemaNodes = 33
        XCTAssertNoThrow(try EthereumABI.checkedDecodeCall(data: data, abi: definition(type: type), limits: limits))
        limits.schemaNodes = 32
        assertLimit(data: data, abi: try definition(type: type), limits: limits)
    }

    func testInputByteLimitsAreInclusive() throws {
        let empty = try definition(inputs: [])
        var limits = EthereumABI.Limits()
        let boundary = empty + String(repeating: " ", count: limits.abiBytes - empty.utf8.count)
        XCTAssertNotNil(EthereumABI.decodeCall(data: selector, abi: boundary))
        assertLimit(data: selector, abi: boundary + " ", limits: limits)
        let exact = selector + Data(repeating: 0, count: limits.calldataBytes - selector.count)
        XCTAssertNotNil(EthereumABI.decodeCall(data: exact, abi: empty))
        assertLimit(data: exact + Data([0]), abi: empty, limits: limits)
        limits.abiBytes = empty.utf8.count
        XCTAssertNoThrow(try EthereumABI.checkedDecodeCall(data: selector, abi: empty, limits: limits))
    }

    func testCancellationIsObservedDuringExpansionAndSerialization() throws {
        let data = aliasedNestedArrays(depth: 5)
        let abi = try definition(type: "uint256[][][][][]")
        let observed = Mutex(0)
        _ = try EthereumABI.checkedDecodeCall(data: data, abi: abi, checkCancellation: {
            observed.withLock { $0 += 1 }
        })
        let total = observed.withLock { $0 }
        XCTAssertGreaterThan(total, 32)
        for stop in [16, total / 2, total - 1] {
            let checks = Mutex(0)
            XCTAssertThrowsError(try EthereumABI.checkedDecodeCall(data: data, abi: abi, checkCancellation: {
                if checks.withLock({ $0 += 1; return $0 }) == stop { throw CancellationError() }
            })) {
                XCTAssertTrue($0 is CancellationError)
            }
            XCTAssertEqual(checks.withLock { $0 }, stop)
        }
        XCTAssertNotNil(EthereumABI.decodeCall(data: data, abi: abi))
    }

    func testCancelledTaskDoesNotDecode() async throws {
        let data = selector + word(1)
        let abi = try definition(type: "uint256")
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return EthereumABI.decodeCall(data: data, abi: abi) == nil &&
                WalletEncoding.decodeEthereumCall(data: data, abi: abi) == nil
        }.value
        XCTAssertTrue(cancelled)
    }

    private func aliasedNestedArrays(depth: Int) -> Data {
        var data = selector + word(32)
        for _ in 1..<depth { data += word(2) + word(64) + word(64) }
        return data + word(1) + word(7)
    }

    private func aliasedStrings(count: Int, bytes: Data) -> Data {
        var data = selector + word(32)
        for _ in 0..<count { data += word(count * 32) }
        return data + word(bytes.count) + bytes
    }

    private func word(_ value: Int) -> Data { BigUInt(UInt64(value)).toData(minLength: 32) }

    private func definition(type: String, name: String = "value", components: [[String: Any]]? = nil) throws -> String {
        var input: [String: Any] = ["name": name, "type": type]
        if let components { input["components"] = components }
        return try definition(inputs: [input])
    }

    private func definition(inputs: [[String: Any]]) throws -> String {
        let function: [String: Any] = ["name": "f", "inputs": inputs, "outputs": []]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["01020304": function], options: [.sortedKeys]), as: UTF8.self)
    }

    private func firstInput(_ json: String) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap((object["inputs"] as? [[String: Any]])?.first)
    }

    private func arrayValue(_ json: String) throws -> [Any] { try XCTUnwrap(firstInput(json)["value"] as? [Any]) }

    private func assertLimit(data: Data, abi: String, limits: EthereumABI.Limits = .init(), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EthereumABI.checkedDecodeCall(data: data, abi: abi, limits: limits), file: file, line: line) {
            XCTAssertEqual($0 as? EthereumABI.DecodingFailure, .limitExceeded, file: file, line: line)
        }
    }
}
