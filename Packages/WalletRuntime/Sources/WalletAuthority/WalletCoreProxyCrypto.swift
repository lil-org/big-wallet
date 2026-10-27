import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import CommonCrypto
import CryptoKit
import Dispatch
import Foundation
import Synchronization

enum PBKDF2 {
    private static let maxDerivedKeyLength = 1024

    static func secretSHA256(password: SecretBytes, salt: Data, rounds: Int, keyLength: Int, maximumKeyLength: Int = maxDerivedKeyLength) -> SecretBytes? {
        salt.withUnsafeBytes { saltBytes in
            deriveSecret(password: password, salt: saltBytes, rounds: rounds, keyLength: keyLength,
                maximumKeyLength: maximumKeyLength, algorithm: CCPBKDFAlgorithm(kCCPRFHmacAlgSHA256))
        }
    }

    static func secretSHA256(password: SecretBytes, salt: SecretBytes, rounds: Int, keyLength: Int) -> SecretBytes? {
        try? salt.withUnsafeBytes { saltBytes in
            deriveSecret(password: password, salt: saltBytes, rounds: rounds, keyLength: keyLength,
                maximumKeyLength: maxDerivedKeyLength, algorithm: CCPBKDFAlgorithm(kCCPRFHmacAlgSHA256))
        }
    }

    static func secretSHA512(password: SecretBytes, salt: Data, rounds: Int, keyLength: Int) -> SecretBytes? {
        salt.withUnsafeBytes { saltBytes in
            deriveSecret(password: password, salt: saltBytes, rounds: rounds, keyLength: keyLength,
                maximumKeyLength: maxDerivedKeyLength, algorithm: CCPBKDFAlgorithm(kCCPRFHmacAlgSHA512))
        }
    }

    static func secretSHA512(password: SecretBytes, salt: SecretBytes, rounds: Int, keyLength: Int) -> SecretBytes? {
        try? salt.withUnsafeBytes { saltBytes in
            deriveSecret(password: password, salt: saltBytes, rounds: rounds, keyLength: keyLength,
                maximumKeyLength: maxDerivedKeyLength, algorithm: CCPBKDFAlgorithm(kCCPRFHmacAlgSHA512))
        }
    }

    static func parametersAreValid(rounds: Int, keyLength: Int) -> Bool {
        return parametersAreValid(rounds: rounds, keyLength: keyLength, maximumKeyLength: maxDerivedKeyLength)
    }

    private static func parametersAreValid(rounds: Int, keyLength: Int, maximumKeyLength: Int) -> Bool {
        return rounds > 0 && rounds <= Int(UInt32.max) && keyLength > 0 && keyLength <= maximumKeyLength
    }

    private static func deriveSecret(password: SecretBytes, salt: UnsafeRawBufferPointer, rounds: Int,
                                     keyLength: Int, maximumKeyLength: Int, algorithm: CCPBKDFAlgorithm) -> SecretBytes? {
        guard parametersAreValid(rounds: rounds, keyLength: keyLength, maximumKeyLength: maximumKeyLength) else { return nil }
        return try? password.withUnsafeBytes { passwordBytes in
            try SecretBytes(count: keyLength) { output in
                guard CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), passwordBytes.count,
                    salt.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    algorithm, UInt32(rounds), output.bindMemory(to: UInt8.self).baseAddress!, keyLength) == kCCSuccess else {
                    throw SecretBytes.Error.unavailable
                }
            }
        }
    }
}

enum HMACSHA {
    static func sha512(key: Data, data: Data) -> Data {
        let code = HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(code)
    }

    static func secretSHA512(key: Data, data: SecretBytes) -> SecretBytes? {
        try? data.withUnsafeBytes { bytes in
            key.withUnsafeBytes { secretSHA512(key: $0, data: bytes) }
        }
    }

    static func secretSHA512(key: SecretBytes, data: SecretBytes) -> SecretBytes? {
        try? key.withUnsafeBytes { keyBytes in
            try data.withUnsafeBytes { secretSHA512(key: keyBytes, data: $0) }
        }
    }

    private static func secretSHA512(key: UnsafeRawBufferPointer, data: UnsafeRawBufferPointer) -> SecretBytes {
        SecretBytes(count: Int(CC_SHA512_DIGEST_LENGTH)) { output in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA512), key.baseAddress, key.count,
                data.baseAddress, data.count, output.baseAddress!)
        }
    }
}

enum AESCTR {
    static func crypt(data: UnsafeRawBufferPointer, key: UnsafeRawBufferPointer, iv: Data) -> SecretBytes? {
        guard iv.count == kCCBlockSizeAES128,
              [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count) else { return nil }
        var cryptor: CCCryptorRef?
        let status = iv.withUnsafeBytes { ivBuffer in
            CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                CCPadding(ccNoPadding), ivBuffer.baseAddress, key.baseAddress, key.count,
                nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        }
        guard status == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }
        return try? SecretBytes(count: data.count) { output in
            var moved = 0
            guard CCCryptorUpdate(cryptor, data.baseAddress, data.count, output.baseAddress, output.count, &moved) == kCCSuccess,
                  moved == output.count else { throw SecretBytes.Error.unavailable }
        }
    }

}

enum Ed25519 {
    static func publicKey(seed: SecretBytes) -> Data? {
        guard let privateKey = signingPrivateKey(seed: seed) else { return nil }
        return privateKey.publicKey.rawRepresentation
    }

    static func sign(message: Data, seed: SecretBytes) -> Data? {
        guard let privateKey = signingPrivateKey(seed: seed) else { return nil }
        return try? privateKey.signature(for: message)
    }

    static func sign<Messages: Sequence>(messages: Messages, seed: SecretBytes) -> [Data]? where Messages.Element == Data {
        guard let privateKey = signingPrivateKey(seed: seed) else { return nil }
        var signatures = [Data]()
        signatures.reserveCapacity(messages.underestimatedCount)
        for message in messages {
            guard let signature = try? privateKey.signature(for: message) else { return nil }
            signatures.append(signature)
        }
        return signatures
    }

    private static func signingPrivateKey(seed: SecretBytes) -> Curve25519.Signing.PrivateKey? {
        guard seed.count == 32 else { return nil }
        return try? seed.withTemporaryData { try Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
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

    @_optimize(speed)
    static func deriveSecret(password: SecretBytes, salt: Data, n: Int, r: Int, p: Int, dkLen: Int) -> SecretBytes? {
        guard parametersAreValid(n: n, r: r, p: p, dkLen: dkLen),
              let initial = PBKDF2.secretSHA256(password: password, salt: salt, rounds: 1,
                keyLength: p * 128 * r, maximumKeyLength: maxInitialDerivedKeyLength) else { return nil }
        defer { initial.invalidate() }
        guard let input = try? initial.withUnsafeBytes({ bytes in
            SecretBytes(count: bytes.count) { destination in
                let words = destination.bindMemory(to: UInt32.self)
                for index in words.indices {
                    let offset = index * 4
                    words[index] = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                        | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
                }
            }
        }) else { return nil }
        defer { input.invalidate() }
        guard let mixed = deriveROMix(input: input, n: n, r: r, p: p) else { return nil }
        defer { mixed.invalidate() }
        guard let mixedBytes = try? mixed.withUnsafeBytes({ bytes in
            SecretBytes(count: bytes.count) { destination in
                let words = bytes.bindMemory(to: UInt32.self)
                for index in words.indices {
                    let word = words[index]
                    let offset = index * 4
                    destination[offset] = UInt8(word & 0xff)
                    destination[offset + 1] = UInt8((word >> 8) & 0xff)
                    destination[offset + 2] = UInt8((word >> 16) & 0xff)
                    destination[offset + 3] = UInt8((word >> 24) & 0xff)
                }
            }
        }) else { return nil }
        defer { mixedBytes.invalidate() }
        return PBKDF2.secretSHA256(password: password, salt: mixedBytes, rounds: 1, keyLength: dkLen)
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
    private static func deriveROMix(input: SecretBytes, n: Int, r: Int, p: Int) -> SecretBytes? {
        try? input.withUnsafeBytes { bytes in
            try SecretBytes(count: bytes.count) { output in
                let inputWords = bytes.bindMemory(to: UInt32.self)
                let outputWords = output.bindMemory(to: UInt32.self)
                guard let inputBase = inputWords.baseAddress, let outputBase = outputWords.baseAddress else {
                    throw SecretBytes.Error.unavailable
                }
                if p > 1, ProcessInfo.processInfo.activeProcessorCount > 1,
                   deriveROMixParallel(input: inputBase, output: outputBase, n: n, r: r, p: p) { return }
                guard bwScryptROMixBlocks(inputBase, outputBase, n, r, p) == 1 else {
                    throw SecretBytes.Error.unavailable
                }
            }
        }
    }

    // concurrentPerform joins before these borrowed buffers expire; each worker writes disjoint ranges.
    private struct ROMixBuffers: @unchecked Sendable {
        let input: UnsafePointer<UInt32>
        let output: UnsafeMutablePointer<UInt32>
        let statuses: UnsafeMutablePointer<Int32>

        func mix(worker: Int, n: Int, r: Int, start: Int, count: Int) {
            statuses[worker] = bwScryptROMixBlocksRange(input, output, n, r, start, count)
        }
    }

    @_optimize(speed)
    private static func deriveROMixParallel(input: UnsafePointer<UInt32>, output: UnsafeMutablePointer<UInt32>, n: Int, r: Int, p: Int) -> Bool {
        guard let blockMemoryBytes = multiplied(n, 128 * r), blockMemoryBytes > 0 else { return false }
        let maxWorkerCount = maxParallelROMixMemoryBytes / blockMemoryBytes
        let workerCount = min(p, ProcessInfo.processInfo.activeProcessorCount, maxWorkerCount)
        guard workerCount > 1 else { return false }
        let statuses = UnsafeMutablePointer<Int32>.allocate(capacity: workerCount)
        statuses.initialize(repeating: 0, count: workerCount)
        defer {
            statuses.deinitialize(count: workerCount)
            statuses.deallocate()
        }
        let baseWorkerBlockCount = p / workerCount
        let extraBlocks = p % workerCount
        let buffers = ROMixBuffers(input: input, output: output, statuses: statuses)
        DispatchQueue.concurrentPerform(iterations: workerCount) { workerIndex in
            let blockCount = baseWorkerBlockCount + (workerIndex < extraBlocks ? 1 : 0)
            let blockStart = workerIndex * baseWorkerBlockCount + min(workerIndex, extraBlocks)
            buffers.mix(worker: workerIndex, n: n, r: r, start: blockStart, count: blockCount)
        }
        return (0..<workerCount).allSatisfy { statuses[$0] == 1 }
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

