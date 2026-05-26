// ∅ 2026 lil org

import Foundation

enum BigEndianWordData {
    static func encode(_ words: [UInt32], minLength: Int = 0) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(max(minLength, words.count * 4))

        for word in words.reversed() {
            bytes.append(UInt8((word >> 24) & 0xff))
            bytes.append(UInt8((word >> 16) & 0xff))
            bytes.append(UInt8((word >> 8) & 0xff))
            bytes.append(UInt8(word & 0xff))
        }

        let leadingZeroCount = bytes.firstIndex { $0 != 0 } ?? bytes.count
        bytes.removeFirst(leadingZeroCount)
        if bytes.count < minLength {
            bytes.insert(contentsOf: Array(repeating: 0, count: minLength - bytes.count), at: 0)
        }
        return Data(bytes)
    }
}

struct BigUInt: Equatable, Hashable, Comparable, Sendable, ExpressibleByIntegerLiteral, CustomStringConvertible {

    typealias IntegerLiteralType = UInt64

    private static let decimalBase: UInt32 = 1_000_000_000
    private var words: [UInt32]

    init() {
        words = []
    }

    init(integerLiteral value: UInt64) {
        self.init(value)
    }

    init(_ value: UInt64) {
        let low = UInt32(truncatingIfNeeded: value)
        let high = UInt32(value >> 32)
        words = high == 0 ? (low == 0 ? [] : [low]) : [low, high]
    }

    init(data: Data) {
        self.init()

        for byte in data {
            multiply(bySmall: 256)
            add(small: UInt32(byte))
        }
    }

    init?(decimalString text: String) {
        guard !text.isEmpty else { return nil }
        self.init()

        for scalar in text.unicodeScalars {
            guard scalar.value >= 48, scalar.value <= 57 else { return nil }
            multiply(bySmall: 10)
            add(small: UInt32(scalar.value - 48))
        }
    }

    init?(hexString text: String) {
        var text = text
        guard !text.isEmpty else { return nil }

        let hasHexPrefix = text.hasPrefix("0x") || text.hasPrefix("0X")
        if hasHexPrefix {
            text = String(text.dropFirst(2))
        }

        guard !text.isEmpty else { return nil }

        self.init()

        for scalar in text.unicodeScalars {
            guard let digit = Self.hexDigitValue(scalar) else { return nil }
            multiply(bySmall: 16)
            add(small: digit)
        }
    }

    var isZero: Bool {
        words.isEmpty
    }

    var description: String {
        guard !isZero else { return .zero }

        var value = self
        var parts: [String] = []
        while !value.isZero {
            let division = value.quotientAndRemainder(dividingBy: Self.decimalBase)
            parts.append(String(division.remainder))
            value = division.quotient
        }

        guard let mostSignificant = parts.popLast() else { return .zero }
        return mostSignificant + parts.reversed().map { String(repeating: "0", count: 9 - $0.count) + $0 }.joined()
    }

    var hexString: String {
        toHexString()
    }

    func toHexString(withPrefix: Bool = false) -> String {
        guard let mostSignificant = words.last else {
            return withPrefix ? String.hexPrefix + String.zero : .zero
        }

        let prefix = withPrefix ? String.hexPrefix : ""
        let rest = words.dropLast().reversed().map { word in
            let part = String(word, radix: 16)
            return String(repeating: "0", count: 8 - part.count) + part
        }.joined()
        return prefix + String(mostSignificant, radix: 16) + rest
    }

    func toData(minLength: Int = 0) -> Data {
        return BigEndianWordData.encode(words, minLength: minLength)
    }

    func eth(shortest: Bool = false) -> String {
        let ethDecimal = decimal.multiplying(byPowerOf10: -18)
        let formatter = NumberFormatter()

        if shortest {
            formatter.minimumFractionDigits = 3
            formatter.maximumFractionDigits = 6
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 2
        } else {
            formatter.minimumFractionDigits = 6
            formatter.maximumFractionDigits = 9
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 10
        }

        return formatter.string(from: ethDecimal) ?? .zero
    }

    var ethDouble: Double {
        decimal.multiplying(byPowerOf10: -18).doubleValue
    }

    var gwei: String {
        let division = quotientAndRemainder(dividingBy: Self.decimalBase)
        if !division.quotient.isZero {
            return division.quotient.description
        }

        let gweiDecimal = decimal.multiplying(byPowerOf10: -9)
        let formatter = NumberFormatter()
        formatter.minimumSignificantDigits = 1
        formatter.maximumSignificantDigits = 1
        return formatter.string(from: gweiDecimal) ?? .zero
    }

    private var decimal: NSDecimalNumber {
        NSDecimalNumber(string: description)
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        guard lhs.words.count == rhs.words.count else {
            return lhs.words.count < rhs.words.count
        }

        for index in lhs.words.indices.reversed() {
            if lhs.words[index] != rhs.words[index] {
                return lhs.words[index] < rhs.words[index]
            }
        }
        return false
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let count = max(lhs.words.count, rhs.words.count)
        var result = BigUInt()
        result.words = Array(repeating: 0, count: count)

        var carry: UInt64 = 0
        for index in 0..<count {
            let left = index < lhs.words.count ? UInt64(lhs.words[index]) : 0
            let right = index < rhs.words.count ? UInt64(rhs.words[index]) : 0
            let sum = left + right + carry
            result.words[index] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }

        if carry > 0 {
            result.words.append(UInt32(carry))
        }

        return result
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        guard !lhs.isZero, !rhs.isZero else { return BigUInt() }

        var result = BigUInt()
        result.words = Array(repeating: 0, count: lhs.words.count + rhs.words.count)

        for leftIndex in lhs.words.indices {
            var carry: UInt64 = 0

            for rightIndex in rhs.words.indices {
                let resultIndex = leftIndex + rightIndex
                let product = UInt64(lhs.words[leftIndex]) * UInt64(rhs.words[rightIndex])
                let sum = UInt64(result.words[resultIndex]) + product + carry
                result.words[resultIndex] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }

            var resultIndex = leftIndex + rhs.words.count
            while carry > 0 {
                let sum = UInt64(result.words[resultIndex]) + carry
                result.words[resultIndex] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
                resultIndex += 1
            }
        }

        result.normalize()
        return result
    }

    func quotientAndRemainder(dividingBy divisor: UInt32) -> (quotient: BigUInt, remainder: UInt32) {
        precondition(divisor > 0, "Division by zero")
        guard !isZero else { return (BigUInt(), 0) }

        var quotient = BigUInt()
        quotient.words = Array(repeating: 0, count: words.count)

        var remainder: UInt64 = 0
        for index in words.indices.reversed() {
            let value = (remainder << 32) + UInt64(words[index])
            quotient.words[index] = UInt32(value / UInt64(divisor))
            remainder = value % UInt64(divisor)
        }

        quotient.normalize()
        return (quotient, UInt32(remainder))
    }

    private mutating func multiply(bySmall multiplier: UInt32) {
        guard multiplier != 0, !isZero else {
            words.removeAll()
            return
        }

        guard multiplier != 1 else { return }

        var carry: UInt64 = 0
        for index in words.indices {
            let product = UInt64(words[index]) * UInt64(multiplier) + carry
            words[index] = UInt32(truncatingIfNeeded: product)
            carry = product >> 32
        }

        if carry > 0 {
            words.append(UInt32(carry))
        }
    }

    private mutating func add(small addend: UInt32) {
        var carry = UInt64(addend)
        var index = 0

        while carry > 0 {
            if index == words.count {
                words.append(0)
            }

            let sum = UInt64(words[index]) + carry
            words[index] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
            index += 1
        }
    }

    private mutating func normalize() {
        while words.last == 0 {
            words.removeLast()
        }
    }

    private static func hexDigitValue(_ scalar: UnicodeScalar) -> UInt32? {
        switch scalar.value {
        case 48...57:
            return UInt32(scalar.value - 48)
        case 65...70:
            return UInt32(scalar.value - 55)
        case 97...102:
            return UInt32(scalar.value - 87)
        default:
            return nil
        }
    }

}
