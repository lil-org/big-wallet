// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Secret key used in `crypto_box` cryptography.
public final class CryptoBoxSecretKey {

    /// Determines if the given secret key is valid or not.
    ///
    /// - Parameter data: *non-null* byte array.
    /// - Returns: true if the secret key is valid, false otherwise.
    public static func isValid(data: Data) -> Bool {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWCryptoBoxSecretKeyIsValid(dataData)
    }

    /// Returns the raw data of the given secret-key.
    ///
    /// - Parameter secretKey: *non-null* pointer to a secret key.
    /// - Returns: C-compatible result with a C-compatible byte array.
    public var data: Data {
        return TWDataNSData(TWCryptoBoxSecretKeyData(rawValue))
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = TWCryptoBoxSecretKeyCreate()
    }

    public init?(data: Data) {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        guard let rawValue = TWCryptoBoxSecretKeyCreateWithData(dataData) else {
            return nil
        }
        self.rawValue = rawValue
    }

    deinit {
        TWCryptoBoxSecretKeyDelete(rawValue)
    }

    /// Returns the public key associated with the given `key`.
    ///
    /// - Parameter key: *non-null* pointer to the private key.
    /// - Returns: *non-null* pointer to the corresponding public key.
    public func getPublicKey() -> CryptoBoxPublicKey {
        return CryptoBoxPublicKey(rawValue: TWCryptoBoxSecretKeyGetPublicKey(rawValue))
    }

}
