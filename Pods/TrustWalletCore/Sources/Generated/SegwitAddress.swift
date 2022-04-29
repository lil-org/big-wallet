// Copyright © 2017-2020 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public final class SegwitAddress: Address {

    public static func == (lhs: SegwitAddress, rhs: SegwitAddress) -> Bool {
        return TWSegwitAddressEqual(lhs.rawValue, rhs.rawValue)
    }

    public static func isValidString(string: String) -> Bool {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        return TWSegwitAddressIsValidString(stringString)
    }

    public var description: String {
        return TWStringNSString(TWSegwitAddressDescription(rawValue))
    }

    public var hrp: HRP {
        return HRP(rawValue: TWSegwitAddressHRP(rawValue).rawValue)!
    }

    public var witnessProgram: Data {
        return TWDataNSData(TWSegwitAddressWitnessProgram(rawValue))
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
        guard let rawValue = TWSegwitAddressCreateWithString(stringString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(hrp: HRP, publicKey: PublicKey) {
        rawValue = TWSegwitAddressCreateWithPublicKey(TWHRP(rawValue: hrp.rawValue), publicKey.rawValue)
    }

    deinit {
        TWSegwitAddressDelete(rawValue)
    }

}
