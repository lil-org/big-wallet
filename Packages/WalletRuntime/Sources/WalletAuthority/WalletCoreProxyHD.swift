import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import CryptoKit
import Foundation

private func appendBigEndianUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

enum BIP32 {
    private static let extendedPublicKeyVersion: UInt32 = 0x0488b21e

    struct Node {
        let privateKey: SecretBytes
        let chainCode: SecretBytes
        let parentFingerprint: UInt32

        func invalidate() {
            privateKey.invalidate()
            chainCode.invalidate()
        }
    }

    struct PublicNode {
        fileprivate let compressedPublicKey: Data
        fileprivate let uncompressedPublicKeyData: Data
        fileprivate let chainCode: Data

        fileprivate init?(compressedPublicKey: Data, chainCode: Data) {
            guard let uncompressedPublicKeyData = Secp256k1.uncompressedPublicKey(fromCompressed: compressedPublicKey) else { return nil }
            self.compressedPublicKey = compressedPublicKey
            self.uncompressedPublicKeyData = uncompressedPublicKeyData
            self.chainCode = chainCode
        }

        fileprivate init(compressedPublicKey: Data, uncompressedPublicKeyData: Data, chainCode: Data) {
            self.compressedPublicKey = compressedPublicKey
            self.uncompressedPublicKeyData = uncompressedPublicKeyData
            self.chainCode = chainCode
        }

        func child(index: UInt32) -> PublicNode? {
            return BIP32.deriveChildPublicNode(node: self, index: index)
        }

        func uncompressedPublicKey(addressIndex: UInt32) -> Data? {
            return BIP32.deriveChildPublicKeyMaterial(node: self, index: addressIndex)?.uncompressedPublicKey
        }
    }

    struct ExtendedPublicKey {
        private let node: PublicNode

        init?(_ extended: String) {
            guard let payload = Base58.decodeCheck(extended), payload.count == 78 else { return nil }
            let version = UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16 | UInt32(payload[2]) << 8 | UInt32(payload[3])
            guard version == BIP32.extendedPublicKeyVersion else { return nil }
            let publicKey = Data(payload[45..<78])
            guard let node = PublicNode(compressedPublicKey: publicKey, chainCode: Data(payload[13..<45])) else { return nil }
            self.node = node
        }

        func publicNode(change: UInt32) -> PublicNode? {
            return node.child(index: change)
        }

        func uncompressedPublicKey(path: DerivationPath) -> Data? {
            return publicNode(change: path.change)?.uncompressedPublicKey(addressIndex: path.address)
        }
    }

    static func derivePrivateNode(seed: SecretBytes, path: DerivationPath, includeParentFingerprint: Bool = true) -> Node? {
        guard let master = HMACSHA.secretSHA512(key: Data("Bitcoin seed".utf8), data: seed) else { return nil }
        defer { master.invalidate() }
        guard var privateKey = try? master.copy(in: 0..<32),
              var chainCode = try? master.copy(in: 32..<64) else { return nil }
        var transferred = false
        defer {
            if !transferred { privateKey.invalidate(); chainCode.invalidate() }
        }
        var parentFingerprint: UInt32 = 0
        guard Secp256k1.isValidPrivateKey(privateKey) else { return nil }
        for (offset, component) in path.components.enumerated() {
            if includeParentFingerprint, offset == path.components.count - 1 {
                parentFingerprint = fingerprint(privateKey: privateKey)
            }
            guard let child = deriveChildPrivateKey(privateKey: privateKey, chainCode: chainCode,
                index: component.derivationIndex) else { return nil }
            privateKey.invalidate()
            chainCode.invalidate()
            privateKey = child.privateKey
            chainCode = child.chainCode
        }
        transferred = true
        return Node(privateKey: privateKey, chainCode: chainCode, parentFingerprint: parentFingerprint)
    }

    static func serializeExtendedPublicKey(privateKey: SecretBytes, chainCode: SecretBytes, depth: UInt8, parentFingerprint: UInt32, childNumber: UInt32) -> String {
        guard let publicKey = Secp256k1.publicKey(privateKey: privateKey, compressed: true) else { return "" }
        return (try? chainCode.withTemporaryData {
            serializeExtendedPublicKey(publicKey: publicKey, chainCode: $0, depth: depth,
                parentFingerprint: parentFingerprint, childNumber: childNumber)
        }) ?? ""
    }

    static func serializeExtendedPublicKey(publicKey: Data, chainCode: SecretBytes, depth: UInt8, parentFingerprint: UInt32, childNumber: UInt32) -> String {
        (try? chainCode.withTemporaryData {
            serializeExtendedPublicKey(publicKey: publicKey, chainCode: $0, depth: depth,
                parentFingerprint: parentFingerprint, childNumber: childNumber)
        }) ?? ""
    }

    static func serializeExtendedPublicKey(publicKey: Data, chainCode: Data, depth: UInt8, parentFingerprint: UInt32, childNumber: UInt32) -> String {
        guard publicKey.count == 33 else { return "" }
        var payload = Data()
        appendBigEndianUInt32(extendedPublicKeyVersion, to: &payload)
        payload.append(depth)
        appendBigEndianUInt32(parentFingerprint, to: &payload)
        appendBigEndianUInt32(childNumber, to: &payload)
        payload.append(chainCode)
        payload.append(publicKey)
        return Base58.encodeCheck(payload)
    }

    static func fingerprint(privateKey: SecretBytes) -> UInt32 {
        guard let publicKey = Secp256k1.publicKey(privateKey: privateKey, compressed: true) else { return 0 }
        let sha = Data(SHA256.hash(data: publicKey))
        let ripemd = RIPEMD160.hash(sha)
        return UInt32(ripemd[0]) << 24 | UInt32(ripemd[1]) << 16 | UInt32(ripemd[2]) << 8 | UInt32(ripemd[3])
    }

    private static func deriveChildPrivateKey(privateKey: SecretBytes, chainCode: SecretBytes, index: UInt32) -> (privateKey: SecretBytes, chainCode: SecretBytes)? {
        let data: SecretBytes
        if index >= 0x80000000 {
            guard let prepared = try? privateKey.withUnsafeBytes({ key in
                SecretBytes(count: 37) { output in
                    output[0] = 0
                    UnsafeMutableRawBufferPointer(rebasing: output[1..<33]).copyMemory(from: key)
                    storeBigEndian(index, in: output, at: 33)
                }
            }) else { return nil }
            data = prepared
        } else {
            guard let publicKey = Secp256k1.publicKey(privateKey: privateKey, compressed: true) else { return nil }
            data = SecretBytes(count: publicKey.count + 4) { output in
                publicKey.withUnsafeBytes {
                    UnsafeMutableRawBufferPointer(rebasing: output[..<publicKey.count]).copyMemory(from: $0)
                }
                storeBigEndian(index, in: output, at: publicKey.count)
            }
        }
        defer { data.invalidate() }
        guard let digest = HMACSHA.secretSHA512(key: chainCode, data: data) else { return nil }
        defer { digest.invalidate() }
        guard let tweak = try? digest.copy(in: 0..<32) else { return nil }
        defer { tweak.invalidate() }
        guard let child = Secp256k1.addPrivateKey(privateKey, tweak: tweak),
              let childChain = try? digest.copy(in: 32..<64) else { return nil }
        return (child, childChain)
    }

    private static func deriveChildPublicNode(node: PublicNode, index: UInt32) -> PublicNode? {
        guard let child = deriveChildPublicKeyMaterial(node: node, index: index),
              let compressedPublicKey = Secp256k1.compressedPublicKey(fromUncompressed: child.uncompressedPublicKey)
        else { return nil }
        return PublicNode(compressedPublicKey: compressedPublicKey,
                          uncompressedPublicKeyData: child.uncompressedPublicKey,
                          chainCode: child.chainCode)
    }

    private static func deriveChildPublicKeyMaterial(node: PublicNode,
                                                     index: UInt32) -> (uncompressedPublicKey: Data, chainCode: Data)? {
        guard index < 0x80000000 else { return nil }
        var data = node.compressedPublicKey
        appendBigEndianUInt32(index, to: &data)
        let digest = HMACSHA.sha512(key: node.chainCode, data: data)
        let il = digest.prefixData(32)
        guard Secp256k1.isValidPrivateKey(il),
              let ilPublic = Secp256k1.publicKey(privateKey: il, compressed: false),
              let child = Secp256k1.addPublicKeys(ilPublic, node.uncompressedPublicKeyData) else { return nil }
        return (child, digest.suffixData(32))
    }
}


enum SLIP10Ed25519 {
    struct Node {
        let privateKey: SecretBytes
        let chainCode: SecretBytes
        let parentFingerprint: UInt32

        func invalidate() {
            privateKey.invalidate()
            chainCode.invalidate()
        }
    }

    struct PrivateKeyMaterial {
        let privateKey: SecretBytes
        let chainCode: SecretBytes

        func invalidate() {
            privateKey.invalidate()
            chainCode.invalidate()
        }
    }

    static func derivePrivateNode(seed: SecretBytes, path: DerivationPath, includeParentFingerprint: Bool = true) -> Node? {
        guard let digest = HMACSHA.secretSHA512(key: Data("ed25519 seed".utf8), data: seed) else { return nil }
        defer { digest.invalidate() }
        guard var key = try? digest.copy(in: 0..<32),
              var chainCode = try? digest.copy(in: 32..<64) else { return nil }
        var transferred = false
        defer {
            if !transferred { key.invalidate(); chainCode.invalidate() }
        }
        var parentFingerprint: UInt32 = 0
        for (offset, component) in path.components.enumerated() {
            if includeParentFingerprint, offset == path.components.count - 1 {
                parentFingerprint = fingerprint(seed: key)
            }
            guard let child = deriveChildPrivateKey(key: key, chainCode: chainCode, component: component) else { return nil }
            key.invalidate()
            chainCode.invalidate()
            key = child.privateKey
            chainCode = child.chainCode
        }
        transferred = true
        return Node(privateKey: key, chainCode: chainCode, parentFingerprint: parentFingerprint)
    }

    static func derivePrivateKeyMaterial(seed: SecretBytes, path: DerivationPath) -> PrivateKeyMaterial? {
        guard let node = derivePrivateNode(seed: seed, path: path, includeParentFingerprint: false) else { return nil }
        return PrivateKeyMaterial(privateKey: node.privateKey, chainCode: node.chainCode)
    }

    static func deriveChildPrivateKeyMaterial(parent: PrivateKeyMaterial, component: DerivationPath.Component) -> PrivateKeyMaterial? {
        guard let child = deriveChildPrivateKey(key: parent.privateKey, chainCode: parent.chainCode, component: component) else { return nil }
        return PrivateKeyMaterial(privateKey: child.privateKey, chainCode: child.chainCode)
    }

    private static func deriveChildPrivateKey(key: SecretBytes, chainCode: SecretBytes, component: DerivationPath.Component) -> (privateKey: SecretBytes, chainCode: SecretBytes)? {
        guard component.hardened,
              let data = try? key.withUnsafeBytes({ keyBytes in
                  SecretBytes(count: keyBytes.count + 5) { output in
                      output[0] = 0
                      UnsafeMutableRawBufferPointer(rebasing: output[1..<(keyBytes.count + 1)]).copyMemory(from: keyBytes)
                      storeBigEndian(component.derivationIndex, in: output, at: keyBytes.count + 1)
                  }
              }) else { return nil }
        defer { data.invalidate() }
        guard let digest = HMACSHA.secretSHA512(key: chainCode, data: data) else { return nil }
        defer { digest.invalidate() }
        guard let child = try? digest.copy(in: 0..<32), let childChain = try? digest.copy(in: 32..<64) else { return nil }
        return (child, childChain)
    }

    private static func fingerprint(seed: SecretBytes) -> UInt32 {
        guard let publicKey = Ed25519.publicKey(seed: seed) else { return 0 }
        let sha = Data(SHA256.hash(data: Data([0x01]) + publicKey))
        let ripemd = RIPEMD160.hash(sha)
        return UInt32(ripemd[0]) << 24 | UInt32(ripemd[1]) << 16 | UInt32(ripemd[2]) << 8 | UInt32(ripemd[3])
    }
}

private func storeBigEndian(_ value: UInt32, in bytes: UnsafeMutableRawBufferPointer, at offset: Int) {
    bytes[offset] = UInt8((value >> 24) & 0xff)
    bytes[offset + 1] = UInt8((value >> 16) & 0xff)
    bytes[offset + 2] = UInt8((value >> 8) & 0xff)
    bytes[offset + 3] = UInt8(value & 0xff)
}

enum BIP39 {
    private static let allowedWordCounts = Set([12, 15, 18, 21, 24])
    private static let words: [String] = BIP39WordList.words.split(separator: "\n").map(String.init)
    private static let wordBytes = words.map { Array($0.utf8) }
    private static let maximumMnemonicBytes = 24 * (wordBytes.map(\.count).max() ?? 0) + 23

    static func isValidMnemonic(_ mnemonic: String) -> Bool {
        isValidMnemonic(mnemonic.utf8)
    }

    static func isValidMnemonic<Bytes: Collection>(_ mnemonic: Bytes) -> Bool where Bytes.Element == UInt8 {
        guard mnemonic.count <= maximumMnemonicBytes else { return false }
        let parts = mnemonic.split(separator: 32, omittingEmptySubsequences: false)
        guard allowedWordCounts.contains(parts.count) else { return false }
        let totalBits = parts.count * 11
        guard let packed = try? SecretBytes(count: (totalBits + 7) / 8, initialize: { output in
            output.initializeMemory(as: UInt8.self, repeating: 0)
            for (wordOffset, word) in parts.enumerated() {
                guard let index = wordIndex(word) else { throw WalletKeyStoreError.invalidMnemonic }
                for bitOffset in 0..<11 {
                    let bit = (index >> (10 - bitOffset)) & 1
                    let position = wordOffset * 11 + bitOffset
                    output[position / 8] |= UInt8(bit << (7 - position % 8))
                }
            }
        }) else { return false }
        defer { packed.invalidate() }
        let entropyBitCount = totalBits * 32 / 33
        let checksumBitCount = totalBits - entropyBitCount
        return (try? packed.withUnsafeBytes { bytes in
            var hash = SHA256()
            hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<(entropyBitCount / 8)]))
            let digest = hash.finalize()
            let shift = 8 - checksumBitCount
            let actual: UInt8 = bytes[entropyBitCount / 8] >> shift
            let firstDigestByte: UInt8 = digest.withUnsafeBytes { $0[0] }
            let expected: UInt8 = firstDigestByte >> shift
            return actual == expected
        }) == true
    }

    private static func wordIndex<Bytes: Collection>(_ bytes: Bytes) -> Int? where Bytes.Element == UInt8 {
        var lowerBound = 0
        var upperBound = wordBytes.count
        while lowerBound < upperBound {
            let index = lowerBound + (upperBound - lowerBound) / 2
            let word = wordBytes[index]
            if bytes.elementsEqual(word) { return index }
            if bytes.lexicographicallyPrecedes(word) {
                upperBound = index
            } else {
                lowerBound = index + 1
            }
        }
        return nil
    }

    static func generateSecretMnemonic() throws -> SecretBytes {
        let entropy = try SecureRandom.secret(count: 16)
        defer { entropy.invalidate() }
        let digest = try entropy.sha256Digest()
        return try entropy.withUnsafeBytes { bytes in
            let entropyBits = bytes.count * 8
            let wordCount = (entropyBits + entropyBits / 32) / 11
            func selectedWord(_ offset: Int) -> String {
                var index = 0
                for bitOffset in 0..<11 {
                    let position = offset * 11 + bitOffset
                    let byte = position < entropyBits ? bytes[position / 8] : digest[(position - entropyBits) / 8]
                    let bit = (byte >> (7 - position % 8)) & 1
                    index = index * 2 + Int(bit)
                }
                return words[index]
            }
            let count = (0..<wordCount).reduce(wordCount - 1) { $0 + selectedWord($1).utf8.count }
            return SecretBytes(count: count) { output in
                var position = 0
                for index in 0..<wordCount {
                    if index > 0 { output[position] = 32; position += 1 }
                    for byte in selectedWord(index).utf8 { output[position] = byte; position += 1 }
                }
            }
        }
    }

    static func secretSeed(mnemonic: SecretBytes, passphrase: String) -> SecretBytes? {
        guard (try? mnemonic.withUnsafeBytes({ isValidMnemonic($0) })) == true else { return nil }
        let normalizedPassphrase = passphrase.decomposedStringWithCompatibilityMapping
        let prefix = Array("mnemonic".utf8)
        let salt = SecretBytes(count: prefix.count + normalizedPassphrase.utf8.count) { output in
            for (index, byte) in prefix.enumerated() { output[index] = byte }
            for (index, byte) in normalizedPassphrase.utf8.enumerated() { output[prefix.count + index] = byte }
        }
        defer { salt.invalidate() }
        return PBKDF2.secretSHA512(password: mnemonic, salt: salt, rounds: 2048, keyLength: 64)
    }

}
