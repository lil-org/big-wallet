// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents a derivation path index in C++ with value and hardened flag.
public final class DerivationPathIndex {

    /// Returns numeric value of an Index.
    ///
    /// - Parameter index: Index to get the numeric value of.
    public var value: UInt32 {
        return TWDerivationPathIndexValue(rawValue)
    }

    /// Returns hardened flag of an Index.
    ///
    /// - Parameter index: Index to get hardened flag.
    /// - Returns: true if hardened, false otherwise.
    public var hardened: Bool {
        return TWDerivationPathIndexHardened(rawValue)
    }

    /// Returns the string description of a derivation path index.
    ///
    /// - Parameter path: Index to get the address of.
    /// - Returns: The string description of the derivation path index.
    public var description: String {
        return TWStringNSString(TWDerivationPathIndexDescription(rawValue))
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init(value: UInt32, hardened: Bool) {
        rawValue = TWDerivationPathIndexCreate(value, hardened)
    }

    deinit {
        TWDerivationPathIndexDelete(rawValue)
    }

}
