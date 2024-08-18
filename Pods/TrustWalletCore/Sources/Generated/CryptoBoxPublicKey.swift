// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Public key used in `crypto_box` cryptography.
public final class CryptoBoxPublicKey {

    /// Determines if the given public key is valid or not.
    ///
    /// - Parameter data: *non-null* byte array.
    /// - Returns: true if the public key is valid, false otherwise.
    public static func isValid(data: Data) -> Bool {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWCryptoBoxPublicKeyIsValid(dataData)
    }

    /// Returns the raw data of the given public-key.
    ///
    /// - Parameter publicKey: *non-null* pointer to a public key.
    /// - Returns: C-compatible result with a C-compatible byte array.
    public var data: Data {
        return TWDataNSData(TWCryptoBoxPublicKeyData(rawValue))
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init?(data: Data) {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        guard let rawValue = TWCryptoBoxPublicKeyCreateWithData(dataData) else {
            return nil
        }
        self.rawValue = rawValue
    }

    deinit {
        TWCryptoBoxPublicKeyDelete(rawValue)
    }

}
