// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

extension BitcoinSigHashType {

    /// Determines if the given sig hash is single
    ///
    /// - Parameter type: sig hash type
    /// - Returns: true if the sigh hash type is single, false otherwise
    public func isSingle() -> Bool {
        return TWBitcoinSigHashTypeIsSingle(TWBitcoinSigHashType(rawValue: rawValue))
    }


    /// Determines if the given sig hash is none
    ///
    /// - Parameter type: sig hash type
    /// - Returns: true if the sigh hash type is none, false otherwise
    public func isNone() -> Bool {
        return TWBitcoinSigHashTypeIsNone(TWBitcoinSigHashType(rawValue: rawValue))
    }

}
