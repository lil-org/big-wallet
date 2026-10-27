import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import Foundation

enum Secp256k1 {
    static func isValidPrivateKey(_ secret: SecretBytes) -> Bool {
        guard secret.count == 32 else { return false }
        return (try? secret.withUnsafeBytes {
            bwSecp256k1IsValidPrivateKey($0.bindMemory(to: UInt8.self).baseAddress!) == 1
        }) == true
    }

    static func isValidPrivateKey(_ data: Data) -> Bool {
        guard data.count == 32 else { return false }
        return withPointer(data) { bwSecp256k1IsValidPrivateKey($0) == 1 } ?? false
    }

    static func isValidPublicKey(_ data: Data) -> Bool {
        guard data.count == 65, data.first == 0x04 else { return false }
        return withPointer(data) { bwSecp256k1IsValidPublicKey($0, data.count) == 1 } ?? false
    }

    static func publicKey(privateKey: Data, compressed: Bool) -> Data? {
        guard privateKey.count == 32 else { return nil }
        let outputCount = compressed ? 33 : 65
        var output = Data(repeating: 0, count: outputCount)
        var length = outputCount
        let result = withPointer(privateKey) { privateKeyPointer in
            output.withUnsafeMutableBytes { outputBuffer in
                guard let outputPointer = outputBuffer.bindMemory(to: UInt8.self).baseAddress else { return Int32(0) }
                return bwSecp256k1CreatePublicKey(privateKeyPointer,
                                                  outputPointer,
                                                  &length,
                                                  compressed ? 1 : 0)
            }
        }
        guard result == 1, length == outputCount else { return nil }
        return output
    }

    static func publicKey(privateKey: SecretBytes, compressed: Bool) -> Data? {
        guard privateKey.count == 32 else { return nil }
        return try? privateKey.withUnsafeBytes { privateKeyBytes -> Data? in
            let outputCount = compressed ? 33 : 65
            var output = Data(repeating: 0, count: outputCount)
            var length = outputCount
            let result = output.withUnsafeMutableBytes { outputBuffer in
                bwSecp256k1CreatePublicKey(privateKeyBytes.bindMemory(to: UInt8.self).baseAddress!,
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress!, &length, compressed ? 1 : 0)
            }
            guard result == 1, length == outputCount else { return nil }
            return output
        }
    }

    static func sign(digest: Data, privateKey: SecretBytes) -> Data? {
        guard digest.count == 32, privateKey.count == 32 else { return nil }
        return try? privateKey.withUnsafeBytes { privateKeyBytes -> Data? in
            var signature = Data(repeating: 0, count: 65)
            let result = digest.withUnsafeBytes { digestBytes in
                signature.withUnsafeMutableBytes { signatureBytes in
                    bwSecp256k1SignRecoverable(digestBytes.bindMemory(to: UInt8.self).baseAddress!,
                        privateKeyBytes.bindMemory(to: UInt8.self).baseAddress!,
                        signatureBytes.bindMemory(to: UInt8.self).baseAddress!)
                }
            }
            return result == 1 ? signature : nil
        }
    }

    static func addPrivateKey(_ privateKey: SecretBytes, tweak: SecretBytes) -> SecretBytes? {
        guard privateKey.count == 32, tweak.count == 32 else { return nil }
        return try? privateKey.withUnsafeBytes { keyBytes in
            try tweak.withUnsafeBytes { tweakBytes in
                try SecretBytes(count: 32) { output in
                    guard bwSecp256k1TweakAddPrivateKey(keyBytes.bindMemory(to: UInt8.self).baseAddress!,
                        tweakBytes.bindMemory(to: UInt8.self).baseAddress!,
                        output.bindMemory(to: UInt8.self).baseAddress!) == 1 else {
                        throw SecretBytes.Error.unavailable
                    }
                }
            }
        }
    }

    static func recoverPublicKey(signature: Data, digest: Data) -> Data? {
        guard signature.count == 65, digest.count == 32 else { return nil }
        var publicKey = Data(repeating: 0, count: 65)
        let result = withPointer(digest) { digestPointer in
            withPointer(signature) { signaturePointer in
                publicKey.withUnsafeMutableBytes { publicKeyBuffer in
                    guard let publicKeyPointer = publicKeyBuffer.bindMemory(to: UInt8.self).baseAddress else { return Int32(0) }
                    return bwSecp256k1RecoverPublicKey(digestPointer, signaturePointer, publicKeyPointer)
                }
            } ?? Int32(0)
        }
        guard result == 1 else { return nil }
        return publicKey
    }

    static func uncompressedPublicKey(fromCompressed compressed: Data) -> Data? {
        guard compressed.count == 33,
              compressed[compressed.startIndex] == 0x02 || compressed[compressed.startIndex] == 0x03 else { return nil }
        return serializePublicKey(compressed, compressed: false)
    }

    static func compressedPublicKey(fromUncompressed uncompressed: Data) -> Data? {
        guard uncompressed.count == 65, uncompressed.first == 0x04 else { return nil }
        return serializePublicKey(uncompressed, compressed: true)
    }

    static func addPublicKeys(_ lhs: Data, _ rhs: Data) -> Data? {
        guard isSupportedPublicKeyEncoding(lhs), isSupportedPublicKeyEncoding(rhs) else { return nil }
        var publicKey = Data(repeating: 0, count: 65)
        let result = withPointer(lhs) { lhsPointer in
            withPointer(rhs) { rhsPointer in
                publicKey.withUnsafeMutableBytes { publicKeyBuffer in
                    guard let publicKeyPointer = publicKeyBuffer.bindMemory(to: UInt8.self).baseAddress else { return Int32(0) }
                    return bwSecp256k1CombinePublicKeys(lhsPointer,
                                                        lhs.count,
                                                        rhsPointer,
                                                        rhs.count,
                                                        publicKeyPointer)
                }
            } ?? Int32(0)
        }
        guard result == 1 else { return nil }
        return publicKey
    }

    private static func serializePublicKey(_ publicKey: Data, compressed: Bool) -> Data? {
        guard isSupportedPublicKeyEncoding(publicKey) else { return nil }
        let outputCount = compressed ? 33 : 65
        var output = Data(repeating: 0, count: outputCount)
        var length = outputCount
        let result = withPointer(publicKey) { publicKeyPointer in
            output.withUnsafeMutableBytes { outputBuffer in
                guard let outputPointer = outputBuffer.bindMemory(to: UInt8.self).baseAddress else { return Int32(0) }
                return bwSecp256k1SerializePublicKey(publicKeyPointer,
                                                     publicKey.count,
                                                     outputPointer,
                                                     &length,
                                                     compressed ? 1 : 0)
            }
        }
        guard result == 1, length == outputCount else { return nil }
        return output
    }

    private static func isSupportedPublicKeyEncoding(_ data: Data) -> Bool {
        if data.count == 33, data.first == 0x02 || data.first == 0x03 {
            return true
        }
        return data.count == 65 && data.first == 0x04
    }

    private static func withPointer<Result>(_ data: Data, _ body: (UnsafePointer<UInt8>) -> Result) -> Result? {
        guard !data.isEmpty else { return nil }
        return data.withUnsafeBytes { buffer in
            guard let pointer = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return body(pointer)
        }
    }
}

@_silgen_name("bw_secp256k1_is_valid_private_key")
private func bwSecp256k1IsValidPrivateKey(_ privateKey32: UnsafePointer<UInt8>) -> Int32

@_silgen_name("bw_secp256k1_create_public_key")
private func bwSecp256k1CreatePublicKey(_ privateKey32: UnsafePointer<UInt8>,
                                        _ publicKeyOut: UnsafeMutablePointer<UInt8>,
                                        _ publicKeyLength: UnsafeMutablePointer<Int>,
                                        _ compressed: Int32) -> Int32

@_silgen_name("bw_secp256k1_is_valid_public_key")
private func bwSecp256k1IsValidPublicKey(_ publicKey: UnsafePointer<UInt8>,
                                         _ publicKeyLength: Int) -> Int32

@_silgen_name("bw_secp256k1_serialize_public_key")
private func bwSecp256k1SerializePublicKey(_ publicKey: UnsafePointer<UInt8>,
                                           _ publicKeyLength: Int,
                                           _ publicKeyOut: UnsafeMutablePointer<UInt8>,
                                           _ publicKeyOutLength: UnsafeMutablePointer<Int>,
                                           _ compressed: Int32) -> Int32

@_silgen_name("bw_secp256k1_sign_recoverable")
private func bwSecp256k1SignRecoverable(_ digest32: UnsafePointer<UInt8>,
                                        _ privateKey32: UnsafePointer<UInt8>,
                                        _ signature65Out: UnsafeMutablePointer<UInt8>) -> Int32

@_silgen_name("bw_secp256k1_recover_public_key")
private func bwSecp256k1RecoverPublicKey(_ digest32: UnsafePointer<UInt8>,
                                         _ signature65: UnsafePointer<UInt8>,
                                         _ publicKey65Out: UnsafeMutablePointer<UInt8>) -> Int32

@_silgen_name("bw_secp256k1_combine_public_keys")
private func bwSecp256k1CombinePublicKeys(_ leftPublicKey: UnsafePointer<UInt8>,
                                          _ leftPublicKeyLength: Int,
                                          _ rightPublicKey: UnsafePointer<UInt8>,
                                          _ rightPublicKeyLength: Int,
                                          _ publicKey65Out: UnsafeMutablePointer<UInt8>) -> Int32

@_silgen_name("bw_secp256k1_tweak_add_private_key")
private func bwSecp256k1TweakAddPrivateKey(_ privateKey32: UnsafePointer<UInt8>,
                                           _ tweak32: UnsafePointer<UInt8>,
                                           _ privateKey32Out: UnsafeMutablePointer<UInt8>) -> Int32

