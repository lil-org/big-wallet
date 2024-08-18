// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// `crypto_box` encryption algorithms.
public struct CryptoBox {

    /// Encrypts message using `my_secret` and `other_pubkey`.
    /// The output will have a randomly generated nonce prepended to it.
    /// The output will be Overhead + 24 bytes longer than the original.
    ///
    /// - Parameter mySecret: *non-null* pointer to my secret key.
    /// - Parameter otherPubkey: *non-null* pointer to other's public key.
    /// - Parameter message: *non-null* pointer to the message to be encrypted.
    /// - Returns: *nullable* pointer to the encrypted message with randomly generated nonce prepended to it.
    public static func encryptEasy(mySecret: CryptoBoxSecretKey, otherPubkey: CryptoBoxPublicKey, message: Data) -> Data {
        let messageData = TWDataCreateWithNSData(message)
        defer {
            TWDataDelete(messageData)
        }
        return TWDataNSData(TWCryptoBoxEncryptEasy(mySecret.rawValue, otherPubkey.rawValue, messageData))
    }

    /// Decrypts box produced by `TWCryptoBoxEncryptEasy`.
    /// We assume a 24-byte nonce is prepended to the encrypted text in box.
    ///
    /// - Parameter mySecret: *non-null* pointer to my secret key.
    /// - Parameter otherPubkey: *non-null* pointer to other's public key.
    /// - Parameter encrypted: *non-null* pointer to the encrypted message with nonce prepended to it.
    /// - Returns: *nullable* pointer to the decrypted message.
    public static func decryptEasy(mySecret: CryptoBoxSecretKey, otherPubkey: CryptoBoxPublicKey, encrypted: Data) -> Data? {
        let encryptedData = TWDataCreateWithNSData(encrypted)
        defer {
            TWDataDelete(encryptedData)
        }
        guard let result = TWCryptoBoxDecryptEasy(mySecret.rawValue, otherPubkey.rawValue, encryptedData) else {
            return nil
        }
        return TWDataNSData(result)
    }


    init() {
    }


}
