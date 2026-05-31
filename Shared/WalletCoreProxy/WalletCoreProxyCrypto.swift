// ∅ 2026 lil org

import CommonCrypto
import CryptoKit
import Dispatch
import Foundation

enum PBKDF2 {
    private static let maxDerivedKeyLength = 1024

    static func sha256(password: Data, salt: Data, rounds: Int, keyLength: Int) -> Data {
        derive(password: password,
               salt: salt,
               rounds: rounds,
               keyLength: keyLength,
               maximumKeyLength: maxDerivedKeyLength,
               algorithm: CCPBKDFAlgorithm(kCCPRFHmacAlgSHA256))
    }

    static func sha256(password: Data, salt: Data, rounds: Int, keyLength: Int, maximumKeyLength: Int) -> Data {
        derive(password: password,
               salt: salt,
               rounds: rounds,
               keyLength: keyLength,
               maximumKeyLength: maximumKeyLength,
               algorithm: CCPBKDFAlgorithm(kCCPRFHmacAlgSHA256))
    }

    static func sha512(password: Data, salt: Data, rounds: Int, keyLength: Int) -> Data {
        derive(password: password,
               salt: salt,
               rounds: rounds,
               keyLength: keyLength,
               maximumKeyLength: maxDerivedKeyLength,
               algorithm: CCPBKDFAlgorithm(kCCPRFHmacAlgSHA512))
    }

    static func parametersAreValid(rounds: Int, keyLength: Int) -> Bool {
        return parametersAreValid(rounds: rounds, keyLength: keyLength, maximumKeyLength: maxDerivedKeyLength)
    }

    private static func parametersAreValid(rounds: Int, keyLength: Int, maximumKeyLength: Int) -> Bool {
        return rounds > 0 && rounds <= Int(UInt32.max) && keyLength > 0 && keyLength <= maximumKeyLength
    }

    private static func derive(password: Data,
                               salt: Data,
                               rounds: Int,
                               keyLength: Int,
                               maximumKeyLength: Int,
                               algorithm: CCPBKDFAlgorithm) -> Data {
        guard parametersAreValid(rounds: rounds, keyLength: keyLength, maximumKeyLength: maximumKeyLength) else { return Data() }
        var output = [UInt8](repeating: 0, count: keyLength)
        let status = output.withUnsafeMutableBytes { outputBuffer in
            password.withUnsafeBytes { passwordBuffer in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                                         password.count,
                                         saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                         salt.count,
                                         algorithm,
                                         UInt32(rounds),
                                         outputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                         keyLength)
                }
            }
        }
        guard status == kCCSuccess else { return Data() }
        return Data(output)
    }
}

enum HMACSHA {
    static func sha256(key: Data, data: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(code)
    }

    static func sha512(key: Data, data: Data) -> Data {
        let code = HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(code)
    }
}

enum AESCTR {
    static func crypt(data: Data, key: Data, iv: Data) -> Data? {
        guard iv.count == kCCBlockSizeAES128,
              [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count) else { return nil }
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt),
                                        CCMode(kCCModeCTR),
                                        CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding),
                                        ivBuffer.baseAddress,
                                        keyBuffer.baseAddress,
                                        key.count,
                                        nil,
                                        0,
                                        0,
                                        CCModeOptions(kCCModeOptionCTR_BE),
                                        &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let updateStatus = data.withUnsafeBytes { dataBuffer in
            CCCryptorUpdate(cryptor, dataBuffer.baseAddress, data.count, &output, output.count, &moved)
        }
        guard updateStatus == kCCSuccess else { return nil }
        if moved == output.count { return Data(output) }
        return Data(output.prefix(moved))
    }
}

enum Ed25519 {
    static func publicKey(seed: Data) -> Data? {
        guard let privateKey = signingPrivateKey(seed: seed) else { return nil }
        return privateKey.publicKey.rawRepresentation
    }

    static func sign(message: Data, seed: Data) -> Data? {
        guard let privateKey = signingPrivateKey(seed: seed),
              let signature = try? privateKey.signature(for: message) else { return nil }
        return signature
    }

    static func sign<Messages: Sequence>(messages: Messages, seed: Data) -> [Data]? where Messages.Element == Data {
        guard let privateKey = signingPrivateKey(seed: seed) else { return nil }

        var signatures = [Data]()
        signatures.reserveCapacity(messages.underestimatedCount)
        for message in messages {
            guard let signature = try? privateKey.signature(for: message) else { return nil }
            signatures.append(signature)
        }
        return signatures
    }

    private static func signingPrivateKey(seed: Data) -> Curve25519.Signing.PrivateKey? {
        guard seed.count == 32 else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }
}

enum Keccak256 {
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

    static func hash(_ data: Data) -> Data {
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

    static func hash(parts: [Data]) -> Data {
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

enum RIPEMD160 {
    private static let r1: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
        4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13,
    ]
    private static let r2: [Int] = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
        12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11,
    ]
    private static let s1: [UInt32] = [
        11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
        7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
        11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
        11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
        9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6,
    ]
    private static let s2: [UInt32] = [
        8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
        9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
        9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
        15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
        8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11,
    ]

    static func hash(_ data: Data) -> Data {
        var message = Array(data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 0, to: 64, by: 8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xefcdab89
        var h2: UInt32 = 0x98badcfe
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xc3d2e1f0

        for offset in stride(from: 0, to: message.count, by: 64) {
            var x = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                x[i] = UInt32(message[offset + 4 * i])
                    | (UInt32(message[offset + 4 * i + 1]) << 8)
                    | (UInt32(message[offset + 4 * i + 2]) << 16)
                    | (UInt32(message[offset + 4 * i + 3]) << 24)
            }
            var al = h0, bl = h1, cl = h2, dl = h3, el = h4
            var ar = h0, br = h1, cr = h2, dr = h3, er = h4
            for j in 0..<80 {
                let tl = rotate(al &+ f(j, bl, cl, dl) &+ x[r1[j]] &+ k1(j), by: s1[j]) &+ el
                al = el; el = dl; dl = rotate(cl, by: 10); cl = bl; bl = tl
                let tr = rotate(ar &+ f(79 - j, br, cr, dr) &+ x[r2[j]] &+ k2(j), by: s2[j]) &+ er
                ar = er; er = dr; dr = rotate(cr, by: 10); cr = br; br = tr
            }
            let t = h1 &+ cl &+ dr
            h1 = h2 &+ dl &+ er
            h2 = h3 &+ el &+ ar
            h3 = h4 &+ al &+ br
            h4 = h0 &+ bl &+ cr
            h0 = t
        }

        var out = Data()
        for word in [h0, h1, h2, h3, h4] {
            out.append(UInt8(word & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 24) & 0xff))
        }
        return out
    }

    private static func f(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch j {
        case 0...15: return x ^ y ^ z
        case 16...31: return (x & y) | (~x & z)
        case 32...47: return (x | ~y) ^ z
        case 48...63: return (x & z) | (y & ~z)
        default: return x ^ (y | ~z)
        }
    }

    private static func k1(_ j: Int) -> UInt32 {
        switch j {
        case 0...15: return 0
        case 16...31: return 0x5a827999
        case 32...47: return 0x6ed9eba1
        case 48...63: return 0x8f1bbcdc
        default: return 0xa953fd4e
        }
    }

    private static func k2(_ j: Int) -> UInt32 {
        switch j {
        case 0...15: return 0x50a28be6
        case 16...31: return 0x5c4dd124
        case 32...47: return 0x6d703ef3
        case 48...63: return 0x7a6d76e9
        default: return 0
        }
    }

    private static func rotate(_ value: UInt32, by amount: UInt32) -> UInt32 {
        return (value << amount) | (value >> (32 - amount))
    }
}


enum Scrypt {
    private static let maxDerivedKeyLength = 1024
    private static let maxInitialDerivedKeyLength = 8192
    private static let maxMemoryBytes = 256 * 1024 * 1024
    private static let maxParallelROMixMemoryBytes = 64 * 1024 * 1024

#if DEBUG
    private struct CacheKey: Hashable {
        let passwordDigest: Data
        let saltDigest: Data
        let n: Int
        let r: Int
        let p: Int
        let dkLen: Int
    }

    private static let maxCacheEntries = 16
    private static let cacheLock = NSLock()
    private static var cache = [CacheKey: Data]()
    private static var cacheOrder = [CacheKey]()

    private static var testCacheEnabled: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func testCacheKey(password: Data, salt: Data, n: Int, r: Int, p: Int, dkLen: Int) -> CacheKey? {
        guard testCacheEnabled else { return nil }
        return CacheKey(passwordDigest: Data(SHA256.hash(data: password)),
                        saltDigest: Data(SHA256.hash(data: salt)),
                        n: n,
                        r: r,
                        p: p,
                        dkLen: dkLen)
    }

    private static func cachedKey(for cacheKey: CacheKey) -> Data? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[cacheKey]
    }

    private static func storeCachedKey(_ derivedKey: Data, for cacheKey: CacheKey) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[cacheKey] = derivedKey
        cacheOrder.removeAll { $0 == cacheKey }
        cacheOrder.append(cacheKey)
        while cacheOrder.count > maxCacheEntries {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
#endif

    @_optimize(speed)
    static func deriveKey(password: Data, salt: Data, n: Int, r: Int, p: Int, dkLen: Int) -> Data {
        guard parametersAreValid(n: n, r: r, p: p, dkLen: dkLen) else { return Data() }
#if DEBUG
        let cacheKey = testCacheKey(password: password, salt: salt, n: n, r: r, p: p, dkLen: dkLen)
        if let cacheKey, let cached = cachedKey(for: cacheKey) {
            return cached
        }
#endif
        let blockSize = 128 * r
        let initialKeyLength = p * blockSize
        let initialKey = PBKDF2.sha256(password: password,
                                       salt: salt,
                                       rounds: 1,
                                       keyLength: initialKeyLength,
                                       maximumKeyLength: maxInitialDerivedKeyLength)
        guard initialKey.count == initialKeyLength else { return Data() }
        let initialWords = littleEndianWords(initialKey)
        guard let words = deriveROMix(input: initialWords, n: n, r: r, p: p) else { return Data() }
        let derivedKey = PBKDF2.sha256(password: password, salt: data(fromLittleEndianWords: words), rounds: 1, keyLength: dkLen)
#if DEBUG
        if let cacheKey {
            storeCachedKey(derivedKey, for: cacheKey)
        }
#endif
        return derivedKey
    }

    static func parametersAreValid(n: Int, r: Int, p: Int, dkLen: Int) -> Bool {
        guard n > 1, n & (n - 1) == 0, r > 0, p > 0, dkLen > 0, dkLen <= maxDerivedKeyLength,
              let blockSize = multiplied(128, r),
              let initialSize = multiplied(p, blockSize),
              initialSize <= maxInitialDerivedKeyLength,
              let blockMemory = multiplied(n, blockSize),
              let totalMemory = multiplied(p, blockMemory),
              totalMemory <= maxMemoryBytes else { return false }
        return true
    }

    private static func multiplied(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? nil : result.partialValue
    }

    @_optimize(speed)
    private static func deriveROMix(input: [UInt32], n: Int, r: Int, p: Int) -> [UInt32]? {
        var output = Array(repeating: UInt32(0), count: input.count)
        if p > 1,
           ProcessInfo.processInfo.activeProcessorCount > 1,
           deriveROMixParallel(input: input, output: &output, n: n, r: r, p: p) {
            return output
        }

        guard deriveROMixSequential(input: input, output: &output, n: n, r: r, p: p) else { return nil }
        return output
    }

    @_optimize(speed)
    private static func deriveROMixParallel(input: [UInt32], output: inout [UInt32], n: Int, r: Int, p: Int) -> Bool {
        let blockWords = 32 * r
        guard input.count == blockWords * p, output.count == input.count else { return false }
        guard let blockBytes = multiplied(blockWords, MemoryLayout<UInt32>.size),
              let blockMemoryBytes = multiplied(n, blockBytes),
              blockMemoryBytes > 0 else { return false }

        let maxWorkerCount = maxParallelROMixMemoryBytes / blockMemoryBytes
        let workerCount = min(p, ProcessInfo.processInfo.activeProcessorCount, maxWorkerCount)
        guard workerCount > 1 else { return false }

        let statuses = UnsafeMutablePointer<Int32>.allocate(capacity: workerCount)
        statuses.initialize(repeating: 0, count: workerCount)
        defer {
            statuses.deinitialize(count: workerCount)
            statuses.deallocate()
        }

        return input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                guard let inputBase = inputBuffer.baseAddress,
                      let outputBase = outputBuffer.baseAddress else { return false }

                let baseWorkerBlockCount = p / workerCount
                let extraBlocks = p % workerCount
                DispatchQueue.concurrentPerform(iterations: workerCount) { workerIndex in
                    let blockCount = baseWorkerBlockCount + (workerIndex < extraBlocks ? 1 : 0)
                    let blockStart = workerIndex * baseWorkerBlockCount + min(workerIndex, extraBlocks)
                    statuses[workerIndex] = bwScryptROMixBlocksRange(inputBase,
                                                                     outputBase,
                                                                     n,
                                                                     r,
                                                                     blockStart,
                                                                     blockCount)
                }

                for workerIndex in 0..<workerCount where statuses[workerIndex] != 1 {
                    return false
                }
                return true
            }
        }
    }

    @_optimize(speed)
    private static func deriveROMixSequential(input: [UInt32], output: inout [UInt32], n: Int, r: Int, p: Int) -> Bool {
        return input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                guard let inputBase = inputBuffer.baseAddress,
                      let outputBase = outputBuffer.baseAddress else { return false }
                return bwScryptROMixBlocks(inputBase, outputBase, n, r, p) == 1
            }
        }
    }

    @_optimize(speed)
    private static func littleEndianWords(_ data: Data) -> [UInt32] {
        precondition(data.count.isMultiple(of: 4))
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var words = [UInt32](repeating: 0, count: bytes.count / 4)
            for index in words.indices {
                let offset = index * 4
                words[index] = UInt32(bytes[offset])
                    | (UInt32(bytes[offset + 1]) << 8)
                    | (UInt32(bytes[offset + 2]) << 16)
                    | (UInt32(bytes[offset + 3]) << 24)
            }
            return words
        }
    }

    @_optimize(speed)
    private static func data(fromLittleEndianWords words: [UInt32]) -> Data {
        var data = Data(count: words.count * 4)
        data.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for index in words.indices {
                let offset = index * 4
                let word = words[index]
                bytes[offset] = UInt8(word & 0xff)
                bytes[offset + 1] = UInt8((word >> 8) & 0xff)
                bytes[offset + 2] = UInt8((word >> 16) & 0xff)
                bytes[offset + 3] = UInt8((word >> 24) & 0xff)
            }
        }
        return data
    }
}

@_silgen_name("bw_scrypt_romix_blocks")
private func bwScryptROMixBlocks(_ inputWords: UnsafePointer<UInt32>,
                                 _ outputWords: UnsafeMutablePointer<UInt32>,
                                 _ n: Int,
                                 _ r: Int,
                                 _ p: Int) -> Int32

@_silgen_name("bw_scrypt_romix_blocks_range")
private func bwScryptROMixBlocksRange(_ inputWords: UnsafePointer<UInt32>,
                                      _ outputWords: UnsafeMutablePointer<UInt32>,
                                      _ n: Int,
                                      _ r: Int,
                                      _ blockStart: Int,
                                      _ blockCount: Int) -> Int32
