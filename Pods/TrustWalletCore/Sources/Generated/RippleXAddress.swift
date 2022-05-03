// Copyright © 2017-2020 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public final class RippleXAddress: Address {

    public static func == (lhs: RippleXAddress, rhs: RippleXAddress) -> Bool {
        return TWRippleXAddressEqual(lhs.rawValue, rhs.rawValue)
    }

    public static func isValidString(string: String) -> Bool {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        return TWRippleXAddressIsValidString(stringString)
    }

    public var description: String {
        return TWStringNSString(TWRippleXAddressDescription(rawValue))
    }

    public var tag: UInt32 {
        return TWRippleXAddressTag(rawValue)
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
        guard let rawValue = TWRippleXAddressCreateWithString(stringString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(publicKey: PublicKey, tag: UInt32) {
        rawValue = TWRippleXAddressCreateWithPublicKey(publicKey.rawValue, tag)
    }

    deinit {
        TWRippleXAddressDelete(rawValue)
    }

}
