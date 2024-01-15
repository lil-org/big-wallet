// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Tezos message signing, verification and utilities.
public struct TezosMessageSigner {

    /// Implement format input as described in https://tezostaquito.io/docs/signing/
    ///
    /// - Parameter message: message to format e.g: Hello, World
    /// - Parameter dAppUrl: the app url, e.g: testUrl
    /// - Returns:s the formatted message as a string
    public static func formatMessage(message: String, url: String) -> String {
        let messageString = TWStringCreateWithNSString(message)
        defer {
            TWStringDelete(messageString)
        }
        let urlString = TWStringCreateWithNSString(url)
        defer {
            TWStringDelete(urlString)
        }
        return TWStringNSString(TWTezosMessageSignerFormatMessage(messageString, urlString))
    }

    /// Implement input to payload as described in: https://tezostaquito.io/docs/signing/
    ///
    /// - Parameter message: formatted message to be turned into an hex payload
    /// - Returns: the hexpayload of the formated message as a hex string
    public static func inputToPayload(message: String) -> String {
        let messageString = TWStringCreateWithNSString(message)
        defer {
            TWStringDelete(messageString)
        }
        return TWStringNSString(TWTezosMessageSignerInputToPayload(messageString))
    }

    /// Sign a message as described in https://tezostaquito.io/docs/signing/
    ///
    /// - Parameter privateKey:: the private key used for signing
    /// - Parameter message:: A custom message payload (hex) which is input to the signing.
    /// - Returns:s the signature, Hex-encoded. On invalid input empty string is returned. Returned object needs to be deleted after use.
    public static func signMessage(privateKey: PrivateKey, message: String) -> String {
        let messageString = TWStringCreateWithNSString(message)
        defer {
            TWStringDelete(messageString)
        }
        return TWStringNSString(TWTezosMessageSignerSignMessage(privateKey.rawValue, messageString))
    }

    /// Verify signature for a message as described in https://tezostaquito.io/docs/signing/
    ///
    /// - Parameter pubKey:: pubKey that will verify the message from the signature
    /// - Parameter message:: the message signed as a payload (hex)
    /// - Parameter signature:: in Base58-encoded form.
    /// - Returns:s false on any invalid input (does not throw), true if the message can be verified from the signature
    public static func verifyMessage(pubKey: PublicKey, message: String, signature: String) -> Bool {
        let messageString = TWStringCreateWithNSString(message)
        defer {
            TWStringDelete(messageString)
        }
        let signatureString = TWStringCreateWithNSString(signature)
        defer {
            TWStringDelete(signatureString)
        }
        return TWTezosMessageSignerVerifyMessage(pubKey.rawValue, messageString, signatureString)
    }


    init() {
    }


}
