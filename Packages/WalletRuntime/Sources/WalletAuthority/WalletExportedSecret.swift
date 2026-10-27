import Foundation
import WalletDomain

public final class WalletExportedSecret: Sendable {
    private let bytes: SecretBytes

    init(bytes: SecretBytes) { self.bytes = bytes }

    static func privateKey(_ key: WalletPrivateKey, coin: WalletCoin) throws -> WalletExportedSecret {
        let encoded = try key.withUnsafeBytes { privateBytes in
            switch coin {
            case .ethereum:
                let alphabet = Array("0123456789abcdef".utf8)
                return SecretBytes(count: privateBytes.count * 2) { output in
                    for (index, byte) in privateBytes.enumerated() {
                        output[index * 2] = alphabet[Int(byte >> 4)]
                        output[index * 2 + 1] = alphabet[Int(byte & 15)]
                    }
                }
            case .solana:
                let publicKey = key.publicKeyData(coin: .solana)
                guard publicKey.count == 32 else { throw WalletKeyStoreError.invalidKey }
                let secret = SecretBytes(count: privateBytes.count + publicKey.count) { output in
                    UnsafeMutableRawBufferPointer(rebasing: output[..<privateBytes.count]).copyMemory(from: privateBytes)
                    publicKey.withUnsafeBytes {
                        UnsafeMutableRawBufferPointer(rebasing: output[privateBytes.count...]).copyMemory(from: $0)
                    }
                }
                defer { secret.invalidate() }
                return try secret.withUnsafeBytes(encodeBase58)
            }
        }
        return WalletExportedSecret(bytes: encoded)
    }

    private static func encodeBase58(_ input: UnsafeRawBufferPointer) throws -> SecretBytes {
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
        let leadingZeros = input.prefix(while: { $0 == 0 }).count
        var length = 0
        let digits = SecretBytes(count: input.count * 138 / 100 + 1) { output in
            output.initializeMemory(as: UInt8.self, repeating: 0)
            for byte in input {
                var carry = Int(byte)
                for index in 0..<length {
                    carry += Int(output[index]) * 256
                    output[index] = UInt8(carry % 58)
                    carry /= 58
                }
                while carry > 0 {
                    output[length] = UInt8(carry % 58)
                    length += 1
                    carry /= 58
                }
            }
        }
        defer { digits.invalidate() }
        return try digits.withUnsafeBytes { digits in
            SecretBytes(count: leadingZeros + length) { output in
                for index in 0..<leadingZeros { output[index] = alphabet[0] }
                for index in 0..<length { output[leadingZeros + index] = alphabet[Int(digits[length - index - 1])] }
            }
        }
    }

    @discardableResult
    public func withText(_ consume: (String) -> Void) -> Bool {
        do {
            try bytes.withUTF8String(consume)
            return true
        } catch {
            return false
        }
    }

    public func invalidate() { bytes.invalidate() }

    deinit { invalidate() }
}
