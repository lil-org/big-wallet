// Copyright © 2017-2020 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public final class SolanaAddress: Address {

    public var description: String {
        return TWStringNSString(TWSolanaAddressDescription(rawValue))
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
        guard let rawValue = TWSolanaAddressCreateWithString(stringString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    deinit {
        TWSolanaAddressDelete(rawValue)
    }

    public func defaultTokenAddress(tokenMintAddress: String) -> String? {
        let tokenMintAddressString = TWStringCreateWithNSString(tokenMintAddress)
        defer {
            TWStringDelete(tokenMintAddressString)
        }
        guard let result = TWSolanaAddressDefaultTokenAddress(rawValue, tokenMintAddressString) else {
            return nil
        }
        return TWStringNSString(result)
    }

}
