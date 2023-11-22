// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Bitcoin message signing and verification.
///
/// Bitcoin Core and some other wallets support a message signing & verification format, to create a proof (a signature)
/// that someone has access to the private keys of a specific address.
/// This feature currently works on old legacy addresses only.
public struct BitcoinMessageSigner {

    /// Sign a message.
    ///
    /// - Parameter privateKey:: the private key used for signing
    /// - Parameter address:: the address that matches the privateKey, must be a legacy address (P2PKH)
    /// - Parameter message:: A custom message which is input to the signing.
    /// - Note: Address is derived assuming compressed public key format.
    /// - Returns:s the signature, Base64-encoded.  On invalid input empty string is returned. Returned object needs to be deleteed after use.
    public static func signMessage(privateKey: PrivateKey, address: String, message: String) -> String {
        let addressString = TWStringCreateWithNSString(address)
        defer {
            TWStringDelete(addressString)
        }
        let messageString = TWStringCreateWithNSString(message)
        defer {
            TWStringDelete(messageString)
        }
        return TWStringNSString(TWBitcoinMessageSignerSignMessage(privateKey.rawValue, addressString, messageString))
    }

    /// Verify signature for a message.
    ///
    /// - Parameter address:: address to use, only legacy is supported
    /// - Parameter message:: the message signed (without prefix)
    /// - Parameter signature:: in Base64-encoded form.
    /// - Returns:s false on any invalid input (does not throw).
    public static func verifyMessage(address: String, message: String, signature: String) -> Bool {
        let addressString = TWStringCreateWithNSString(address)
        defer {
            TWStringDelete(addressString)
        }
        let messageString = TWStringCreateWithNSString(message)
        defer {
            TWStringDelete(messageString)
        }
        let signatureString = TWStringCreateWithNSString(signature)
        defer {
            TWStringDelete(signatureString)
        }
        return TWBitcoinMessageSignerVerifyMessage(addressString, messageString, signatureString)
    }


    init() {
    }


}
