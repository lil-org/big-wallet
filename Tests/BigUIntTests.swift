// ∅ 2026 lil org

import XCTest
@testable import Big_Wallet

final class BigUIntTests: XCTestCase {

    func testHexParsingAndOutput() {
        XCTAssertEqual(BigUInt(hexString: "0")?.hexString, "0")
        XCTAssertEqual(BigUInt(hexString: "0x000000")?.hexString, "0")
        XCTAssertEqual(BigUInt(hexString: "0XABCDEF")?.hexString, "abcdef")
        XCTAssertEqual(BigUInt(hexString: "ffffffffffffffff")?.description, "18446744073709551615")
        XCTAssertEqual(BigUInt(hexString: "10000000000000000")?.description, "18446744073709551616")

        let twoTo256MinusOne = String(repeating: "f", count: 64)
        XCTAssertEqual(BigUInt(hexString: twoTo256MinusOne)?.hexString, twoTo256MinusOne)

        XCTAssertNil(BigUInt(hexString: ""))
        XCTAssertNil(BigUInt(hexString: "0x"))
        XCTAssertNil(BigUInt(hexString: "0X"))
        XCTAssertNil(BigUInt(hexString: "-1"))
        XCTAssertNil(BigUInt(hexString: "0xz"))
    }

    func testDecimalParsingAndOutput() {
        XCTAssertEqual(BigUInt(decimalString: "0")?.description, "0")
        XCTAssertEqual(BigUInt(decimalString: "000001")?.description, "1")
        XCTAssertEqual(BigUInt(decimalString: "18446744073709551616")?.hexString, "10000000000000000")

        // Selected conversion case adapted from grachyov's MIT-licensed upstream integer tests.
        let hexSample = "123456789ABCDEFEDCBA98765432123456789ABCDEF"
        let decimalSample = "425693205796080237694414176550132631862392541400559"
        let value = BigUInt(hexString: hexSample)
        XCTAssertEqual(value?.description, decimalSample)
        XCTAssertEqual(BigUInt(decimalString: decimalSample)?.hexString, hexSample.lowercased())

        XCTAssertNil(BigUInt(decimalString: ""))
        XCTAssertNil(BigUInt(decimalString: "-1"))
        XCTAssertNil(BigUInt(decimalString: "12.3"))
        XCTAssertNil(BigUInt(decimalString: "12349A"))
    }

    func testBigEndianDataRoundTrip() {
        XCTAssertEqual(BigUInt(data: Data()).description, "0")
        XCTAssertEqual(BigUInt(data: Data([0, 0, 1])).hexString, "1")
        XCTAssertEqual(BigUInt(data: Data([0x12, 0x34, 0xab, 0xcd])).toData(), Data([0x12, 0x34, 0xab, 0xcd]))
        XCTAssertEqual(BigUInt(1).toData(minLength: 4), Data([0, 0, 0, 1]))
        XCTAssertEqual(BigUInt().toData(minLength: 2), Data([0, 0]))
    }

    func testMultiplication() {
        let sample = BigUInt(hexString: "123456789abcdef")!
        XCTAssertEqual((BigUInt() * sample).description, "0")
        XCTAssertEqual((BigUInt(2) * BigUInt(3)).description, "6")

        let fee = BigUInt(21_000) * BigUInt(decimalString: "1000000000")!
        XCTAssertEqual(fee.description, "21000000000000")
        XCTAssertEqual(fee.hexString, "1319718a5000")

        let maxUInt64Squared = BigUInt(UInt64.max) * BigUInt(UInt64.max)
        XCTAssertEqual(maxUInt64Squared.hexString, "fffffffffffffffe0000000000000001")

        let maxUInt128 = BigUInt(hexString: "ffffffffffffffffffffffffffffffff")!
        XCTAssertEqual((maxUInt128 * maxUInt128).hexString, "fffffffffffffffffffffffffffffffe00000000000000000000000000000001")
    }

    func testSubtraction() {
        XCTAssertEqual((BigUInt(7) - BigUInt(3)).description, "4")
        XCTAssertEqual((BigUInt(0x1_0000_0000) - BigUInt(1)).hexString, "ffffffff")

        let twoTo256 = BigUInt(hexString: "10000000000000000000000000000000000000000000000000000000000000000")!
        let twoTo256MinusOne = String(repeating: "f", count: 64)
        XCTAssertEqual((twoTo256 - BigUInt(1)).hexString, twoTo256MinusOne)
        XCTAssertEqual((BigUInt(hexString: twoTo256MinusOne)! - BigUInt(hexString: twoTo256MinusOne)!).description, "0")
    }

    func testEthAndGweiFormatting() {
        XCTAssertEqual(BigUInt(decimalString: "1000000000000000000")?.eth(), "1")
        XCTAssertEqual(BigUInt(decimalString: "1000000000000000000")?.eth(shortest: true), "1")
        XCTAssertEqual(BigUInt(1).eth(), "0.000000000000000001")

        let fee = BigUInt(21_000) * BigUInt(decimalString: "1000000000")!
        XCTAssertEqual(fee.eth(shortest: true), "0.000021")

        XCTAssertEqual(BigUInt(1).gwei, "0.000000001")
        XCTAssertEqual(BigUInt(decimalString: "1000000000")?.gwei, "1")
        XCTAssertEqual(BigUInt(decimalString: "1500000000")?.gwei, "1")
        XCTAssertEqual(BigUInt(decimalString: "2500000000000000000000000000000")?.gwei, "2500000000000000000000")

        let largeBalance = BigUInt(hexString: "123456789ABCDEFEDCBA98765432123456789ABCDEF")!
        XCTAssertEqual(largeBalance.eth(shortest: true), "430000000000000000000000000000000")
    }

}
