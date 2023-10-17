// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents a FIO Account name
public final class FIOAccount {

    /// Returns the short account string representation.
    ///
    /// - Parameter account: Pointer to a non-null FIO Account
    /// - Returns: Account non-null string representation
    public var description: String {
        return TWStringNSString(TWFIOAccountDescription(rawValue))
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
        guard let rawValue = TWFIOAccountCreateWithString(stringString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    deinit {
        TWFIOAccountDelete(rawValue)
    }

}
