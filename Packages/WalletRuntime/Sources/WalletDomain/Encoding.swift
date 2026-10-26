// ∅ 2026 lil org

import CryptoKit
import Foundation

public enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    private static let decodeMap: [Int8] = {
        var result = [Int8](repeating: -1, count: 128)
        for (index, byte) in alphabet.enumerated() {
            result[Int(byte)] = Int8(index)
        }
        return result
    }()

    public static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var bytes = Array(data)
        var zeroes = 0
        while zeroes < bytes.count, bytes[zeroes] == 0 { zeroes += 1 }
        var encoded = [UInt8]()
        encoded.reserveCapacity(data.count)
        var start = zeroes
        while start < bytes.count {
            var remainder = 0
            for index in start..<bytes.count {
                let value = remainder * 256 + Int(bytes[index])
                bytes[index] = UInt8(value / 58)
                remainder = value % 58
            }
            encoded.append(alphabet[remainder])
            while start < bytes.count, bytes[start] == 0 { start += 1 }
        }
        for _ in 0..<zeroes {
            encoded.append(alphabet[0])
        }
        return String(bytes: encoded.reversed(), encoding: .ascii) ?? ""
    }

    public static func decode(_ string: String) -> Data? {
        guard !string.isEmpty else { return nil }
        let input = Array(string.utf8)
        var zeroes = 0
        while zeroes < input.count, input[zeroes] == alphabet[0] { zeroes += 1 }
        var decoded = [UInt8]()
        decoded.reserveCapacity(input.count)
        for byte in input {
            guard byte < UInt8(decodeMap.count) else { return nil }
            let value = decodeMap[Int(byte)]
            guard value >= 0 else { return nil }
            var carry = Int(value)
            for index in decoded.indices {
                let total = Int(decoded[index]) * 58 + carry
                decoded[index] = UInt8(total & 0xff)
                carry = total >> 8
            }
            while carry > 0 {
                decoded.append(UInt8(carry & 0xff))
                carry >>= 8
            }
        }
        for _ in 0..<zeroes {
            decoded.append(0)
        }
        return Data(decoded.reversed())
    }

    public static func encodeCheck(_ data: Data) -> String {
        return encode(data + checksum(data))
    }

    public static func decodeCheck(_ string: String) -> Data? {
        guard let decoded = decode(string), decoded.count >= 4 else { return nil }
        let payload = decoded.dropLast(4)
        return Data(decoded.suffix(4)) == checksum(payload) ? Data(payload) : nil
    }

    private static func checksum(_ data: Data) -> Data {
        let first = Data(SHA256.hash(data: data))
        return Data(SHA256.hash(data: first)).prefixData(4)
    }
}

extension Data {
    public func prefixData(_ count: Int) -> Data { Data(prefix(count)) }
    public func suffixData(_ count: Int) -> Data { Data(suffix(count)) }

    public func leftPadded(to count: Int) -> Data {
        if self.count >= count { return self }
        return Data(repeating: 0, count: count - self.count) + self
    }

    public func removingLeadingZeroBytes() -> Data {
        var index = startIndex
        while index < endIndex, self[index] == 0 {
            index = self.index(after: index)
        }
        return Data(self[index..<endIndex])
    }
}

public struct DerivationPath {
    public struct Component {
        public let value: UInt32
        public let hardened: Bool

        public var derivationIndex: UInt32 { hardened ? value + 0x80000000 : value }

        public init(value: UInt32, hardened: Bool) {
            self.value = value
            self.hardened = hardened
        }
    }

    public let components: [Component]

    public init?(components: [Component]) {
        guard !components.isEmpty,
              components.allSatisfy({ $0.value < 0x80000000 }) else { return nil }
        self.components = components
    }

    public init?(_ string: String) {
        var parts = string.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "m" { parts.removeFirst() }
        guard !parts.isEmpty else { return nil }
        var components = [Component]()
        for part in parts {
            guard !part.isEmpty else { return nil }
            let hardened = part.hasSuffix("'")
            let valueString = hardened ? String(part.dropLast()) : part
            guard !valueString.isEmpty,
                  !valueString.hasPrefix("-"),
                  let value = UInt32(valueString),
                  value < 0x80000000 else { return nil }
            components.append(Component(value: value, hardened: hardened))
        }
        self.components = components
    }

    public var account: UInt32 {
        return value(at: 2)
    }

    public var change: UInt32 {
        return value(at: 3)
    }

    public var address: UInt32 {
        return value(at: 4)
    }

    public var coin: UInt32 {
        return value(at: 1)
    }

    private func value(at index: Int) -> UInt32 {
        guard components.indices.contains(index) else { return 0 }
        return components[index].value
    }
}
