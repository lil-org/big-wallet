// Copyright © 2017-2022 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public struct PBKDF2 {

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
