// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// StarkEx message signing and verification.
///
/// StarkEx and some other wallets support a message signing & verification format, to create a proof (a signature)
/// that someone has access to the private keys of a specific address.
public struct StarkExMessageSigner {

    /// Sign a message.
    ///
    /// - Parameter privateKey:: the private key used for signing
    /// - Parameter message:: A custom hex message which is input to the signing.
    /// - Returns:s the signature, Hex-encoded. On invalid input empty string is returned. Returned object needs to be deleted after use.
    public static func signMessage(privateKey: PrivateKey, message: String) -> String {
        let messageString = TWStringCreateWithNSString(message)
        defer {
            TWStringDelete(messageString)
        }
        return TWStringNSString(TWStarkExMessageSignerSignMessage(privateKey.rawValue, messageString))
    }

    /// Verify signature for a message.
    ///
    /// - Parameter pubKey:: pubKey that will verify and recover the message from the signature
    /// - Parameter message:: the message signed (without prefix) in hex
    /// - Parameter signature:: in Hex-encoded form.
    /// - Returns:s false on any invalid input (does not throw), true if the message can be recovered from the signature
    public static func verifyMessage(pubKey: PublicKey, message: String, signature: String) -> Bool {
        let messageString = TWStringCreateWithNSString(message)
        defer {
            TWStringDelete(messageString)
        }
        let signatureString = TWStringCreateWithNSString(signature)
        defer {
            TWStringDelete(signatureString)
        }
        return TWStarkExMessageSignerVerifyMessage(pubKey.rawValue, messageString, signatureString)
    }


    init() {
    }


}
