// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents a NEAR Account name
public final class NEARAccount {

    /// Returns the user friendly string representation.
    ///
    /// - Parameter account: Pointer to a non-null NEAR Account
    /// - Returns: Non-null string account description
    public var description: String {
        return TWStringNSString(TWNEARAccountDescription(rawValue))
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
        guard let rawValue = TWNEARAccountCreateWithString(stringString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    deinit {
        TWNEARAccountDelete(rawValue)
    }

}
