// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Ethereum message signing and verification.
///
/// Ethereum and some other wallets support a message signing & verification format, to create a proof (a signature)
/// that someone has access to the private keys of a specific address.
public struct EthereumMessageSigner {

    /// Sign a typed message EIP-712 V4.
    ///
    /// - Parameter privateKey:: the private key used for signing
    /// - Parameter messageJson:: A custom typed data message in json
    /// - Returns:s the signature, Hex-encoded. On invalid input empty string is returned. Returned object needs to be deleted after use.
    public static func signTypedMessage(privateKey: PrivateKey, messageJson: String) -> String {
        let messageJsonString = TWStringCreateWithNSString(messageJson)
        defer {
            TWStringDelete(messageJsonString)
        }
        return TWStringNSString(TWEthereumMessageSignerSignTypedMessage(privateKey.rawValue, messageJsonString))
    }

    /// Sign a typed message EIP-712 V4 with EIP-155 replay attack protection.
    ///
    /// - Parameter privateKey:: the private key used for signing
    /// - Parameter messageJson:: A custom typed data message in json
    /// - Parameter chainId:: chainId for eip-155 protection
    /// - Returns:s the signature, Hex-encoded. On invalid input empty string is returned or invalid chainId error message. Returned object needs to be deleted after use.
    public static func signTypedMessageEip155(privateKey: PrivateKey, messageJson: String, chainId: Int32) -> String {
        let messageJsonString = TWStringCreateWithNSString(messageJson)
        defer {
            TWStringDelete(messageJsonString)
        }
        return TWStringNSString(TWEthereumMessageSignerSignTypedMessageEip155(privateKey.rawValue, messageJsonString, Int32(chainId)))
    }

    /// Sign a message.
    ///
    /// - Parameter privateKey:: the private key used for signing
    /// - Parameter message:: A custom message which is input to the signing.
    /// - Returns:s the signature, Hex-encoded. On invalid input empty string is returned. Returned object needs to be deleted after use.
    public static func signMessage(privateKey: PrivateKey, message: String) -> String {
        let messageString = TWStringCreateWithNSString(message)
        defer {
            TWStringDelete(messageString)
        }
        return TWStringNSString(TWEthereumMessageSignerSignMessage(privateKey.rawValue, messageString))
    }

    /// Sign a message with Immutable X msg type.
    ///
    /// - Parameter privateKey:: the private key used for signing
    /// - Parameter message:: A custom message which is input to the signing.
    /// - Returns:s the signature, Hex-encoded. On invalid input empty string is returned. Returned object needs to be deleted after use.
    public static func signMessageImmutableX(privateKey: PrivateKey, message: String) -> String {
        let messageString = TWStringCreateWithNSString(message)
        defer {
            TWStringDelete(messageString)
        }
        return TWStringNSString(TWEthereumMessageSignerSignMessageImmutableX(privateKey.rawValue, messageString))
    }

    /// Sign a message with Eip-155 msg type.
    ///
    /// - Parameter privateKey:: the private key used for signing
    /// - Parameter message:: A custom message which is input to the signing.
    /// - Parameter chainId:: chainId for eip-155 protection
    /// - Returns:s the signature, Hex-encoded. On invalid input empty string is returned. Returned object needs to be deleted after use.
    public static func signMessageEip155(privateKey: PrivateKey, message: String, chainId: Int32) -> String {
        let messageString = TWStringCreateWithNSString(message)
        defer {
            TWStringDelete(messageString)
        }
        return TWStringNSString(TWEthereumMessageSignerSignMessageEip155(privateKey.rawValue, messageString, Int32(chainId)))
    }

    /// Verify signature for a message.
    ///
    /// - Parameter pubKey:: pubKey that will verify and recover the message from the signature
    /// - Parameter message:: the message signed (without prefix)
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
        return TWEthereumMessageSignerVerifyMessage(pubKey.rawValue, messageString, signatureString)
    }


    init() {
    }


}
