// Copyright © 2017-2020 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public final class AnyAddress: Address {

    public static func == (lhs: AnyAddress, rhs: AnyAddress) -> Bool {
        return TWAnyAddressEqual(lhs.rawValue, rhs.rawValue)
    }

    public static func isValid(string: String, coin: CoinType) -> Bool {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        return TWAnyAddressIsValid(stringString, TWCoinType(rawValue: coin.rawValue))
    }

    public var description: String {
        return TWStringNSString(TWAnyAddressDescription(rawValue))
    }

    public var coin: CoinType {
        return CoinType(rawValue: TWAnyAddressCoin(rawValue).rawValue)!
    }

    public var data: Data {
        return TWDataNSData(TWAnyAddressData(rawValue))
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init?(string: String, coin: CoinType) {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        guard let rawValue = TWAnyAddressCreateWithString(stringString, TWCoinType(rawValue: coin.rawValue)) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(publicKey: PublicKey, coin: CoinType) {
        rawValue = TWAnyAddressCreateWithPublicKey(publicKey.rawValue, TWCoinType(rawValue: coin.rawValue))
    }

    deinit {
        TWAnyAddressDelete(rawValue)
    }

}
