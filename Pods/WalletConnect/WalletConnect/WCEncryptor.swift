// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation
import CryptoSwift
import Security

public struct WCEncryptor {
    public static func encrypt(data: Data, with key: Data) throws -> WCEncryptionPayload {
        let ivBytes = randomBytes(16)
        let keyBytes = key.bytes
        let aesCipher = try AES(key: keyBytes, blockMode: CBC(iv: ivBytes))
        let cipherInput = data.bytes
        let encryptedBytes = try aesCipher.encrypt(cipherInput)

        let data = encryptedBytes.toHexString()
        let iv = ivBytes.toHexString()
        let hmac = try computeHMAC(payload: data, iv: iv, key: keyBytes)

        return WCEncryptionPayload(data: data, hmac: hmac, iv: iv)
    }

    public static func decrypt(payload: WCEncryptionPayload, with key: Data) throws -> Data {
        let keyBytes = key.bytes
        let computedHmac = try computeHMAC(payload: payload.data, iv: payload.iv, key: keyBytes)

        guard computedHmac == payload.hmac else {
            throw WCError.badServerResponse
        }

        let dataBytes = Data(hex: payload.data).bytes
        let ivBytes = Data(hex: payload.iv).bytes
        let aesCipher = try AES(key: keyBytes, blockMode: CBC(iv: ivBytes))
        let decryptedBytes = try aesCipher.decrypt(dataBytes)

        return Data(decryptedBytes)
    }

    static func computeHMAC(payload: String, iv: String, key: [UInt8]) throws -> String {
        let payloadBytes = Data(hex: payload)
        let ivBytes = Data(hex: iv)

        let data = payloadBytes + ivBytes
        let hmacBytes = try HMAC(key: key, variant: .sha256).authenticate(data.bytes)
        let hmac = Data(hmacBytes).hex
        return hmac
    }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var bytes = [UInt8].init(repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for i in 1...bytes.count {
                bytes[i] = UInt8(arc4random_uniform(256))
            }
        }
        return bytes
    }
}
