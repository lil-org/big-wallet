// Copyright © 2017-2020 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public final class BitcoinAddress: Address {

    public static func == (lhs: BitcoinAddress, rhs: BitcoinAddress) -> Bool {
        return TWBitcoinAddressEqual(lhs.rawValue, rhs.rawValue)
    }

    public static func isValid(data: Data) -> Bool {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWBitcoinAddressIsValid(dataData)
    }

    public static func isValidString(string: String) -> Bool {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        return TWBitcoinAddressIsValidString(stringString)
    }

    public var description: String {
        return TWStringNSString(TWBitcoinAddressDescription(rawValue))
    }

    public var prefix: UInt8 {
        return TWBitcoinAddressPrefix(rawValue)
    }

    public var keyhash: Data {
        return TWDataNSData(TWBitcoinAddressKeyhash(rawValue))
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init?(string: String) {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        guard let rawValue = TWBitcoinAddressCreateWithString(stringString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init?(data: Data) {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        guard let rawValue = TWBitcoinAddressCreateWithData(dataData) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init?(publicKey: PublicKey, prefix: UInt8) {
        guard let rawValue = TWBitcoinAddressCreateWithPublicKey(publicKey.rawValue, prefix) else {
            return nil
        }
        self.rawValue = rawValue
    }

    deinit {
        TWBitcoinAddressDelete(rawValue)
    }

}
