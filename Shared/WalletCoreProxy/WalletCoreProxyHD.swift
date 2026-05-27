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
        let privateKey: Data
        let chainCode: Data
        let parentFingerprint: UInt32
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

    static func derivePrivateNode(seed: Data, path: DerivationPath, includeParentFingerprint: Bool = true) -> Node? {
        let master = HMACSHA.sha512(key: Data("Bitcoin seed".utf8), data: seed)
        var privateKey = master.prefixData(32)
        var chainCode = master.suffixData(32)
        var parentFingerprint: UInt32 = 0
        guard Secp256k1.isValidPrivateKey(privateKey) else { return nil }
        for (offset, component) in path.components.enumerated() {
            if includeParentFingerprint, offset == path.components.count - 1 {
                parentFingerprint = fingerprint(privateKey: privateKey)
            }
            let childNumber = component.derivationIndex
            guard let child = deriveChildPrivateKey(privateKey: privateKey, chainCode: chainCode, index: childNumber) else { return nil }
            privateKey = child.privateKey
            chainCode = child.chainCode
        }
        return Node(privateKey: privateKey, chainCode: chainCode, parentFingerprint: parentFingerprint)
    }

    static func serializeExtendedPublicKey(privateKey: Data, chainCode: Data, depth: UInt8, parentFingerprint: UInt32, childNumber: UInt32) -> String {
        guard let publicKey = Secp256k1.publicKey(privateKey: privateKey, compressed: true) else { return "" }
        return serializeExtendedPublicKey(publicKey: publicKey,
                                          chainCode: chainCode,
                                          depth: depth,
                                          parentFingerprint: parentFingerprint,
                                          childNumber: childNumber)
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

    static func fingerprint(privateKey: Data) -> UInt32 {
        guard let publicKey = Secp256k1.publicKey(privateKey: privateKey, compressed: true) else { return 0 }
        let sha = Data(SHA256.hash(data: publicKey))
        let ripemd = RIPEMD160.hash(sha)
        return UInt32(ripemd[0]) << 24 | UInt32(ripemd[1]) << 16 | UInt32(ripemd[2]) << 8 | UInt32(ripemd[3])
    }

    private static func deriveChildPrivateKey(privateKey: Data, chainCode: Data, index: UInt32) -> (privateKey: Data, chainCode: Data)? {
        var data = Data()
        if index >= 0x80000000 {
            data.append(0)
            data.append(privateKey)
        } else {
            guard let publicKey = Secp256k1.publicKey(privateKey: privateKey, compressed: true) else { return nil }
            data.append(publicKey)
        }
        appendBigEndianUInt32(index, to: &data)
        let digest = HMACSHA.sha512(key: chainCode, data: data)
        let il = digest.prefixData(32)
        guard let child = Secp256k1.addPrivateKey(privateKey, tweak: il) else { return nil }
        return (child, digest.suffixData(32))
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
        let privateKey: Data
        let chainCode: Data
        let parentFingerprint: UInt32
    }

    struct PrivateKeyMaterial {
        let privateKey: Data
        let chainCode: Data
    }

    static func derivePrivateNode(seed: Data, path: DerivationPath, includeParentFingerprint: Bool = true) -> Node? {
        let digest = HMACSHA.sha512(key: Data("ed25519 seed".utf8), data: seed)
        var key = digest.prefixData(32)
        var chainCode = digest.suffixData(32)
        var parentFingerprint: UInt32 = 0
        for (offset, component) in path.components.enumerated() {
            if includeParentFingerprint, offset == path.components.count - 1 {
                parentFingerprint = fingerprint(seed: key)
            }
            guard let child = deriveChildPrivateKey(key: key, chainCode: chainCode, component: component) else { return nil }
            key = child.privateKey
            chainCode = child.chainCode
        }
        return Node(privateKey: key, chainCode: chainCode, parentFingerprint: parentFingerprint)
    }

    static func derivePrivateKeyMaterial(seed: Data, path: DerivationPath) -> PrivateKeyMaterial? {
        guard let node = derivePrivateNode(seed: seed, path: path, includeParentFingerprint: false) else { return nil }
        return PrivateKeyMaterial(privateKey: node.privateKey, chainCode: node.chainCode)
    }

    static func deriveChildPrivateKeyMaterial(parent: PrivateKeyMaterial, component: DerivationPath.Component) -> PrivateKeyMaterial? {
        guard let child = deriveChildPrivateKey(key: parent.privateKey,
                                                chainCode: parent.chainCode,
                                                component: component) else { return nil }
        return PrivateKeyMaterial(privateKey: child.privateKey, chainCode: child.chainCode)
    }

    private static func deriveChildPrivateKey(key: Data,
                                              chainCode: Data,
                                              component: DerivationPath.Component) -> (privateKey: Data, chainCode: Data)? {
        guard component.hardened else { return nil }
        var data = Data([0])
        data.append(key)
        appendBigEndianUInt32(component.derivationIndex, to: &data)
        let digest = HMACSHA.sha512(key: chainCode, data: data)
        return (digest.prefixData(32), digest.suffixData(32))
    }

    private static func fingerprint(seed: Data) -> UInt32 {
        guard let publicKey = Ed25519.publicKey(seed: seed) else { return 0 }
        let sha = Data(SHA256.hash(data: Data([0x01]) + publicKey))
        let ripemd = RIPEMD160.hash(sha)
        return UInt32(ripemd[0]) << 24 | UInt32(ripemd[1]) << 16 | UInt32(ripemd[2]) << 8 | UInt32(ripemd[3])
    }
}

enum BIP39 {
    private static let allowedWordCounts = Set([12, 15, 18, 21, 24])
    private static let words: [String] = BIP39WordList.words.split(separator: "\n").map(String.init)
    private static let wordIndex: [String: Int] = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })

    static func isValidMnemonic(_ mnemonic: String) -> Bool {
        guard mnemonic == mnemonic.trimmingCharacters(in: .whitespacesAndNewlines),
              !mnemonic.contains("\t"),
              !mnemonic.contains("\n"),
              !mnemonic.contains("  ") else { return false }
        let parts = mnemonic.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard allowedWordCounts.contains(parts.count),
              parts.joined(separator: " ") == mnemonic else { return false }

        var bits = [Bool]()
        bits.reserveCapacity(parts.count * 11)
        for word in parts {
            guard let index = wordIndex[word] else { return false }
            for shift in stride(from: 10, through: 0, by: -1) {
                bits.append(((index >> shift) & 1) == 1)
            }
        }

        let entropyBitCount = bits.count * 32 / 33
        let checksumBitCount = bits.count - entropyBitCount
        guard entropyBitCount.isMultiple(of: 8) else { return false }
        let entropy = data(fromBits: Array(bits.prefix(entropyBitCount)))
        let digest = Data(SHA256.hash(data: entropy))
        let digestBits = Self.bits(from: digest, count: checksumBitCount)
        return Array(bits.suffix(checksumBitCount)) == digestBits
    }

    static func generateMnemonic() -> String {
        let entropy = SecureRandom.data(count: 16)
        return mnemonic(fromEntropy: entropy)
    }

    static func seed(mnemonic: String, passphrase: String) -> Data {
        let normalizedMnemonic = mnemonic.decomposedStringWithCompatibilityMapping
        let normalizedPassphrase = passphrase.decomposedStringWithCompatibilityMapping
        return PBKDF2.sha512(password: Data(normalizedMnemonic.utf8),
                             salt: Data(("mnemonic" + normalizedPassphrase).utf8),
                             rounds: 2048,
                             keyLength: 64)
    }

    private static func mnemonic(fromEntropy entropy: Data) -> String {
        let checksumBitCount = entropy.count * 8 / 32
        var allBits = bits(from: entropy, count: entropy.count * 8)
        allBits += bits(from: Data(SHA256.hash(data: entropy)), count: checksumBitCount)
        var result = [String]()
        result.reserveCapacity(allBits.count / 11)
        for offset in stride(from: 0, to: allBits.count, by: 11) {
            var index = 0
            for bit in allBits[offset..<(offset + 11)] {
                index = (index << 1) | (bit ? 1 : 0)
            }
            result.append(words[index])
        }
        return result.joined(separator: " ")
    }

    private static func bits(from data: Data, count: Int) -> [Bool] {
        var output = [Bool]()
        output.reserveCapacity(count)
        for byte in data {
            for shift in stride(from: 7, through: 0, by: -1) where output.count < count {
                output.append(((byte >> UInt8(shift)) & 1) == 1)
            }
        }
        return output
    }

    private static func data(fromBits bits: [Bool]) -> Data {
        var output = Data()
        for offset in stride(from: 0, to: bits.count, by: 8) {
            var byte: UInt8 = 0
            for bit in bits[offset..<(offset + 8)] {
                byte = (byte << 1) | (bit ? 1 : 0)
            }
            output.append(byte)
        }
        return output
    }

}
