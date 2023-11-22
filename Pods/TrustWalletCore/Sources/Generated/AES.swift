// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// AES encryption/decryption methods.
public struct AES {

    /// Encrypts a block of Data using AES in Cipher Block Chaining (CBC) mode.
    ///
    /// - Parameter key: encryption key Data, must be 16, 24, or 32 bytes long.
    /// - Parameter data: Data to encrypt.
    /// - Parameter iv: initialization vector.
    /// - Parameter mode: padding mode.
    /// - Returns: encrypted Data.
    public static func encryptCBC(key: Data, data: Data, iv: Data, mode: AESPaddingMode) -> Data? {
        let keyData = TWDataCreateWithNSData(key)
        defer {
            TWDataDelete(keyData)
        }
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        let ivData = TWDataCreateWithNSData(iv)
        defer {
            TWDataDelete(ivData)
        }
        guard let result = TWAESEncryptCBC(keyData, dataData, ivData, TWAESPaddingMode(rawValue: mode.rawValue)) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Decrypts a block of data using AES in Cipher Block Chaining (CBC) mode.
    ///
    /// - Parameter key: decryption key Data, must be 16, 24, or 32 bytes long.
    /// - Parameter data: Data to decrypt.
    /// - Parameter iv: initialization vector Data.
    /// - Parameter mode: padding mode.
    /// - Returns: decrypted Data.
    public static func decryptCBC(key: Data, data: Data, iv: Data, mode: AESPaddingMode) -> Data? {
        let keyData = TWDataCreateWithNSData(key)
        defer {
            TWDataDelete(keyData)
        }
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        let ivData = TWDataCreateWithNSData(iv)
        defer {
            TWDataDelete(ivData)
        }
        guard let result = TWAESDecryptCBC(keyData, dataData, ivData, TWAESPaddingMode(rawValue: mode.rawValue)) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Encrypts a block of data using AES in Counter (CTR) mode.
    ///
    /// - Parameter key: encryption key Data, must be 16, 24, or 32 bytes long.
    /// - Parameter data: Data to encrypt.
    /// - Parameter iv: initialization vector Data.
    /// - Returns: encrypted Data.
    public static func encryptCTR(key: Data, data: Data, iv: Data) -> Data? {
        let keyData = TWDataCreateWithNSData(key)
        defer {
            TWDataDelete(keyData)
        }
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        let ivData = TWDataCreateWithNSData(iv)
        defer {
            TWDataDelete(ivData)
        }
        guard let result = TWAESEncryptCTR(keyData, dataData, ivData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Decrypts a block of data using AES in Counter (CTR) mode.
    ///
    /// - Parameter key: decryption key Data, must be 16, 24, or 32 bytes long.
    /// - Parameter data: Data to decrypt.
    /// - Parameter iv: initialization vector Data.
    /// - Returns: decrypted Data.
    public static func decryptCTR(key: Data, data: Data, iv: Data) -> Data? {
        let keyData = TWDataCreateWithNSData(key)
        defer {
            TWDataDelete(keyData)
        }
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        let ivData = TWDataCreateWithNSData(iv)
        defer {
            TWDataDelete(ivData)
        }
        guard let result = TWAESDecryptCTR(keyData, dataData, ivData) else {
            return nil
        }
        return TWDataNSData(result)
    }


    init() {
    }


}
