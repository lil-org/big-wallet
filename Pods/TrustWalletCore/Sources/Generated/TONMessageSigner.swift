// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// TON message signing.
public final class TONMessageSigner {

    /// Signs an arbitrary message to prove ownership of an address for off-chain services.
    /// https://github.com/ton-foundation/specs/blob/main/specs/wtf-0002.md
    ///
    /// - Parameter privateKey:: the private key used for signing
    /// - Parameter message:: A custom message which is input to the signing.
    /// - Returns:s the signature, Hex-encoded. On invalid input null is returned. Returned object needs to be deleted after use.
    public static func signMessage(privateKey: PrivateKey, message: String) -> String? {
        let messageString = TWStringCreateWithNSString(message)
        defer {
            TWStringDelete(messageString)
        }
        guard let result = TWTONMessageSignerSignMessage(privateKey.rawValue, messageString) else {
            return nil
        }
        return TWStringNSString(result)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }


}
