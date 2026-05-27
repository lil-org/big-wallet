// ∅ 2026 lil org

import CryptoKit
import Foundation

enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    private static let map: [UInt8: Int] = {
        var result = [UInt8: Int]()
        for (index, byte) in alphabet.enumerated() {
            result[byte] = index
        }
        return result
    }()

    static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var bytes = Array(data)
        var zeroes = 0
        while zeroes < bytes.count, bytes[zeroes] == 0 { zeroes += 1 }
        var encoded = [UInt8]()
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
        encoded.append(contentsOf: Array(repeating: alphabet[0], count: zeroes))
        return String(bytes: encoded.reversed(), encoding: .ascii) ?? ""
    }

    static func decode(_ string: String) -> Data? {
        guard !string.isEmpty else { return nil }
        let input = Array(string.utf8)
        var zeroes = 0
        while zeroes < input.count, input[zeroes] == alphabet[0] { zeroes += 1 }
        var decoded = [UInt8]()
        for byte in input {
            guard let value = map[byte] else { return nil }
            var carry = value
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
        decoded.append(contentsOf: Array(repeating: 0, count: zeroes))
        return Data(decoded.reversed())
    }

    static func encodeCheck(_ data: Data) -> String {
        return encode(data + checksum(data))
    }

    static func decodeCheck(_ string: String) -> Data? {
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
    func prefixData(_ count: Int) -> Data { Data(prefix(count)) }
    func suffixData(_ count: Int) -> Data { Data(suffix(count)) }

    func leftPadded(to count: Int) -> Data {
        if self.count >= count { return self }
        return Data(repeating: 0, count: count - self.count) + self
    }

    func removingLeadingZeroBytes() -> Data {
        var index = startIndex
        while index < endIndex, self[index] == 0 {
            index = self.index(after: index)
        }
        return Data(self[index..<endIndex])
    }
}

struct DerivationPath {
    struct Component {
        let value: UInt32
        let hardened: Bool

        var derivationIndex: UInt32 { hardened ? value + 0x80000000 : value }
    }

    let components: [Component]

    init?(components: [Component]) {
        guard !components.isEmpty,
              components.allSatisfy({ $0.value < 0x80000000 }) else { return nil }
        self.components = components
    }

    init?(_ string: String) {
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

    var account: UInt32 {
        return value(at: 2)
    }

    var change: UInt32 {
        return value(at: 3)
    }

    var address: UInt32 {
        return value(at: 4)
    }

    var coin: UInt32 {
        return value(at: 1)
    }

    private func value(at index: Int) -> UInt32 {
        guard components.indices.contains(index) else { return 0 }
        return components[index].value
    }
}
