import Foundation

public enum Keccak256 {
    private static let rate = 136
    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    private static let rotation: [Int] = [
        0, 1, 62, 28, 27,
        36, 44, 6, 55, 20,
        3, 10, 43, 25, 39,
        41, 45, 15, 21, 8,
        18, 2, 61, 56, 14,
    ]

    public static func hash(_ data: Data) -> Data {
        var state = [UInt64](repeating: 0, count: 25)
        var blockStart = data.startIndex
        while let blockEnd = data.index(blockStart, offsetBy: rate, limitedBy: data.endIndex) {
            absorbBlock(data[blockStart..<blockEnd], into: &state)
            blockStart = blockEnd
        }

        var finalBlock = [UInt8]()
        finalBlock.reserveCapacity(rate)
        finalBlock.append(contentsOf: data[blockStart..<data.endIndex])
        absorbFinalBlock(&finalBlock, into: &state)
        return output(from: state)
    }

    public static func hash(parts: [Data]) -> Data {
        var state = [UInt64](repeating: 0, count: 25)
        var block = [UInt8]()
        block.reserveCapacity(rate)

        func absorb(_ byte: UInt8) {
            block.append(byte)
            if block.count == rate {
                absorbBlock(block, into: &state)
                block.removeAll(keepingCapacity: true)
            }
        }

        for part in parts {
            for byte in part {
                absorb(byte)
            }
        }

        absorbFinalBlock(&block, into: &state)
        return output(from: state)
    }

    private static func absorbFinalBlock(_ block: inout [UInt8], into state: inout [UInt64]) {
        block.append(0x01)
        if block.count == rate {
            block[rate - 1] |= 0x80
            absorbBlock(block, into: &state)
        } else {
            while block.count < rate - 1 {
                block.append(0)
            }
            block.append(0x80)
            absorbBlock(block, into: &state)
        }
    }

    private static func output(from state: [UInt64]) -> Data {
        var output = Data()
        output.reserveCapacity(32)
        for lane in 0..<4 {
            var value = state[lane]
            for _ in 0..<8 {
                output.append(UInt8(value & 0xff))
                value >>= 8
            }
        }
        return output
    }

    private static func absorbBlock<Bytes: Collection>(_ bytes: Bytes, into state: inout [UInt64]) where Bytes.Element == UInt8 {
        var index = bytes.startIndex
        for lane in 0..<(rate / 8) {
            var value: UInt64 = 0
            for byteIndex in 0..<8 {
                value |= UInt64(bytes[index]) << UInt64(8 * byteIndex)
                index = bytes.index(after: index)
            }
            state[lane] ^= value
        }
        permute(&state)
    }

    private static func permute(_ state: inout [UInt64]) {
        var c = [UInt64](repeating: 0, count: 5)
        var d = [UInt64](repeating: 0, count: 5)
        var b = [UInt64](repeating: 0, count: 25)
        for round in 0..<24 {
            for x in 0..<5 {
                c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ rotateLeft(c[(x + 1) % 5], by: 1)
            }
            for x in 0..<5 {
                for y in 0..<5 {
                    state[x + 5 * y] ^= d[x]
                }
            }

            for x in 0..<5 {
                for y in 0..<5 {
                    let index = x + 5 * y
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = rotateLeft(state[index], by: rotation[index])
                }
            }

            for x in 0..<5 {
                for y in 0..<5 {
                    state[x + 5 * y] = b[x + 5 * y] ^ ((~b[((x + 1) % 5) + 5 * y]) & b[((x + 2) % 5) + 5 * y])
                }
            }
            state[0] ^= roundConstants[round]
        }
    }

    private static func rotateLeft(_ value: UInt64, by amount: Int) -> UInt64 {
        guard amount != 0 else { return value }
        return (value << UInt64(amount)) | (value >> UInt64(64 - amount))
    }
}

