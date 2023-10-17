// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Password-Based Key Derivation Function 2
public struct PBKDF2 {

    /// Derives a key from a password and a salt using PBKDF2 + Sha256.
    ///
    /// - Parameter password: is the master password from which a derived key is generated
    /// - Parameter salt: is a sequence of bits, known as a cryptographic salt
    /// - Parameter iterations: is the number of iterations desired
    /// - Parameter dkLen: is the desired bit-length of the derived key
    /// - Returns: the derived key data.
    public static func hmacSha256(password: Data, salt: Data, iterations: UInt32, dkLen: UInt32) -> Data? {
        let passwordData = TWDataCreateWithNSData(password)
        defer {
            TWDataDelete(passwordData)
        }
        let saltData = TWDataCreateWithNSData(salt)
        defer {
            TWDataDelete(saltData)
        }
        guard let result = TWPBKDF2HmacSha256(passwordData, saltData, iterations, dkLen) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Derives a key from a password and a salt using PBKDF2 + Sha512.
    ///
    /// - Parameter password: is the master password from which a derived key is generated
    /// - Parameter salt: is a sequence of bits, known as a cryptographic salt
    /// - Parameter iterations: is the number of iterations desired
    /// - Parameter dkLen: is the desired bit-length of the derived key
    /// - Returns: the derived key data.
    public static func hmacSha512(password: Data, salt: Data, iterations: UInt32, dkLen: UInt32) -> Data? {
        let passwordData = TWDataCreateWithNSData(password)
        defer {
            TWDataDelete(passwordData)
        }
        let saltData = TWDataCreateWithNSData(salt)
        defer {
            TWDataDelete(saltData)
        }
        guard let result = TWPBKDF2HmacSha512(passwordData, saltData, iterations, dkLen) else {
            return nil
        }
        return TWDataNSData(result)
    }


    init() {
    }


}
