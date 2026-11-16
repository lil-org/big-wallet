import Foundation
import XCTest
@testable import WalletDomain

final class JSONPreflightTests: XCTestCase {
    func testLimitsIncludeKeysAndValuesButIgnoreQuotedSyntax() throws {
        let bytes = #"{"a":[true,null,"\"\\[]{}:, 🪙"],"b":1}"#.utf8
        XCTAssertNoThrow(try JSONPreflight.validate(bytes, maximumDepth: 2, maximumTokens: 8))
        XCTAssertThrowsError(try JSONPreflight.validate(bytes, maximumDepth: 1, maximumTokens: 8)) {
            XCTAssertEqual($0 as? JSONPreflight.Failure, .tooDeep)
        }
        XCTAssertThrowsError(try JSONPreflight.validate(bytes, maximumDepth: 2, maximumTokens: 7)) {
            XCTAssertEqual($0 as? JSONPreflight.Failure, .tooManyTokens)
        }
    }

    func testDuplicateKeysConsumeTokensBeforeSemanticDecoding() throws {
        let bytes = #"{"a":0,"a":0}"#.utf8
        XCTAssertNoThrow(try JSONPreflight.validate(bytes, maximumDepth: 1, maximumTokens: 5))
        XCTAssertThrowsError(try JSONPreflight.validate(bytes, maximumDepth: 1, maximumTokens: 4)) {
            XCTAssertEqual($0 as? JSONPreflight.Failure, .tooManyTokens)
        }
    }

    func testUnclosedStringsAndUnbalancedContainersAreRejected() {
        for body in ["[", "}", "}{", #"{"a":"unterminated}"#] {
            XCTAssertThrowsError(try JSONPreflight.validate(body.utf8, maximumDepth: 64)) {
                XCTAssertEqual($0 as? JSONPreflight.Failure, .unbalanced)
            }
        }
    }

    func testCancellationIsCheckedInsideLongStrings() {
        let bytes = ("\"" + String(repeating: "x", count: 20_000) + "\"").utf8
        var checks = 0
        XCTAssertThrowsError(try JSONPreflight.validate(bytes, maximumDepth: 1) {
            checks += 1
            if checks == 2 { throw CancellationError() }
        }) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(checks, 2)
    }
}
