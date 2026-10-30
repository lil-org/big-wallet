// ∅ 2026 lil org

import Foundation

enum EthereumType {
    static func arrayInfo(_ type: String) -> (elementType: String, count: Int?)? {
        guard let bracket = type.lastIndex(of: "["),
              type.hasSuffix("]") else { return nil }
        let elementType = String(type[..<bracket])
        let countText = type[type.index(after: bracket)..<type.index(before: type.endIndex)]
        guard !elementType.isEmpty else { return nil }
        if countText.isEmpty { return (elementType, nil) }
        guard let count = Int(countText), count > 0 else { return nil }
        return (elementType, count)
    }

    static func integerBitWidth(type: String, prefix: String) -> Int? {
        guard type.hasPrefix(prefix) else { return nil }
        let suffix = type.dropFirst(prefix.count)
        let bitWidth: Int
        if suffix.isEmpty {
            bitWidth = 256
        } else if let parsed = Int(suffix) {
            bitWidth = parsed
        } else {
            return nil
        }
        guard bitWidth >= 8, bitWidth <= 256, bitWidth.isMultiple(of: 8) else { return nil }
        return bitWidth
    }

    static func fixedBytesLength(type: String) -> Int? {
        guard type.hasPrefix("bytes"),
              let length = Int(type.dropFirst(5)),
              length > 0,
              length <= 32 else { return nil }
        return length
    }

    static func twoPower(_ bitWidth: Int) -> BigUInt {
        return cachedTwoPowers[bitWidth] ?? computedTwoPower(bitWidth)
    }

    private static let cachedTwoPowers: [Int: BigUInt] = {
        var result = [Int: BigUInt]()
        var previousPower = BigUInt(1)
        for bitWidth in 1...256 {
            let power = previousPower + previousPower
            if bitWidth.isMultiple(of: 8) {
                result[bitWidth] = power
                result[bitWidth - 1] = previousPower
            }
            previousPower = power
        }
        return result
    }()

    private static func computedTwoPower(_ bitWidth: Int) -> BigUInt {
        var result = BigUInt(1)
        for _ in 0..<bitWidth {
            result = result + result
        }
        return result
    }
}

public enum EthereumCodec {
    public static func checksumAddress(_ address: Data) -> String {
        guard address.count == 20 else { return "" }
        let lowerHex = WalletEncoding.hexString(address)
        let hash = WalletEncoding.hexString(WalletEncoding.keccak256(data: Data(lowerHex.utf8)))
        var output = "0x"
        for (index, scalar) in lowerHex.enumerated() {
            guard let nibble = Int(String(hash[hash.index(hash.startIndex, offsetBy: index)]), radix: 16) else {
                output.append(scalar)
                continue
            }
            output.append(nibble >= 8 ? Character(String(scalar).uppercased()) : scalar)
        }
        return output
    }

    public static func parseAddress(_ string: String) -> Data? {
        let raw = string.cleanHex
        guard raw.count == 40, let data = WalletEncoding.hexData(raw), data.count == 20 else { return nil }
        return data
    }
}

public enum RLP {
    public enum Item {
        case bytes(Data)
        case list([Item])
    }

    public static func encode(_ item: Item) -> Data {
        switch item {
        case let .bytes(data):
            if data.count == 1, let byte = data.first, byte < 0x80 {
                return Data([byte])
            }
            return encodeLength(data.count, offset: 0x80) + data
        case let .list(items):
            let encodedItems = items.map(encode)
            let payloadLength = encodedItems.reduce(0) { $0 + $1.count }
            var payload = Data()
            payload.reserveCapacity(payloadLength)
            for encodedItem in encodedItems {
                payload.append(encodedItem)
            }
            return encodeLength(payload.count, offset: 0xc0) + payload
        }
    }

    public static func bytes(_ data: Data) -> Item {
        return .bytes(data)
    }

    public static func integer(_ data: Data) -> Item {
        return .bytes(data.removingLeadingZeroBytes())
    }

    private static func encodeLength(_ length: Int, offset: UInt8) -> Data {
        if length < 56 {
            return Data([offset + UInt8(length)])
        }
        let lengthBytes = BigUInt(UInt64(length)).toData()
        return Data([offset + 55 + UInt8(lengthBytes.count)]) + lengthBytes
    }
}

