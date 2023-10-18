// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Hash functions
public struct Hash {

    /// Computes the SHA1 of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed SHA1 block of data
    public static func sha1(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashSHA1(dataData))
    }

    /// Computes the SHA256 of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed SHA256 block of data
    public static func sha256(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashSHA256(dataData))
    }

    /// Computes the SHA512 of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed SHA512 block of data
    public static func sha512(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashSHA512(dataData))
    }

    /// Computes the SHA512_256 of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed SHA512_256 block of data
    public static func sha512_256(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashSHA512_256(dataData))
    }

    /// Computes the Keccak256 of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed Keccak256 block of data
    public static func keccak256(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashKeccak256(dataData))
    }

    /// Computes the Keccak512 of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed Keccak512 block of data
    public static func keccak512(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashKeccak512(dataData))
    }

    /// Computes the SHA3_256 of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed SHA3_256 block of data
    public static func sha3_256(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashSHA3_256(dataData))
    }

    /// Computes the SHA3_512 of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed SHA3_512 block of data
    public static func sha3_512(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashSHA3_512(dataData))
    }

    /// Computes the RIPEMD of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed RIPEMD block of data
    public static func ripemd(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashRIPEMD(dataData))
    }

    /// Computes the Blake256 of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed Blake256 block of data
    public static func blake256(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashBlake256(dataData))
    }

    /// Computes the Blake2b of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed Blake2b block of data
    public static func blake2b(data: Data, size: Int) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashBlake2b(dataData, size))
    }

    /// Computes the Groestl512 of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed Groestl512 block of data
    public static func blake2bPersonal(data: Data, personal: Data, outlen: Int) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        let personalData = TWDataCreateWithNSData(personal)
        defer {
            TWDataDelete(personalData)
        }
        return TWDataNSData(TWHashBlake2bPersonal(dataData, personalData, outlen))
    }


    public static func groestl512(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashGroestl512(dataData))
    }

    /// Computes the SHA256D of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed SHA256D block of data
    public static func sha256SHA256(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashSHA256SHA256(dataData))
    }

    /// Computes the SHA256RIPEMD of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed SHA256RIPEMD block of data
    public static func sha256RIPEMD(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashSHA256RIPEMD(dataData))
    }

    /// Computes the SHA3_256RIPEMD of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed SHA3_256RIPEMD block of data
    public static func sha3_256RIPEMD(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashSHA3_256RIPEMD(dataData))
    }

    /// Computes the Blake256D of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed Blake256D block of data
    public static func blake256Blake256(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashBlake256Blake256(dataData))
    }

    /// Computes the Blake256RIPEMD of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed Blake256RIPEMD block of data
    public static func blake256RIPEMD(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashBlake256RIPEMD(dataData))
    }

    /// Computes the Groestl512D of a block of data.
    ///
    /// - Parameter data: Non-null block of data
    /// - Returns: Non-null computed Groestl512D block of data
    public static func groestl512Groestl512(data: Data) -> Data {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataNSData(TWHashGroestl512Groestl512(dataData))
    }


    init() {
    }


}
