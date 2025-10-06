// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public final class WebAuthnSolidity {

    /// Computes WebAuthn message hash to be signed with secp256p1 private key.
    /// 
    /// - Parameter authenticator_data: The authenticator data in hex format.
    /// - Parameter client_data_json: The client data JSON string with a challenge.
    /// - Returns: WebAuthn message hash.
    public static func getMessageHash(authenticatorData: String, clientDataJson: String) -> Data? {
        let authenticatorDataString = TWStringCreateWithNSString(authenticatorData)
        defer {
            TWStringDelete(authenticatorDataString)
        }
        let clientDataJsonString = TWStringCreateWithNSString(clientDataJson)
        defer {
            TWStringDelete(clientDataJsonString)
        }
        guard let result = TWWebAuthnSolidityGetMessageHash(authenticatorDataString, clientDataJsonString) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Converts the original ASN-encoded signature from webauthn to the format accepted by Barz
    /// 
    /// - Parameter authenticator_data: The authenticator data in hex format.
    /// - Parameter client_data_json: The client data JSON string with a challenge.
    /// - Parameter der_signature: original ASN-encoded signature from webauthn.
    /// - Returns: WebAuthn ABI-encoded data.
    public static func getFormattedSignature(authenticatorData: String, clientDataJson: String, derSignature: Data) -> Data? {
        let authenticatorDataString = TWStringCreateWithNSString(authenticatorData)
        defer {
            TWStringDelete(authenticatorDataString)
        }
        let clientDataJsonString = TWStringCreateWithNSString(clientDataJson)
        defer {
            TWStringDelete(clientDataJsonString)
        }
        let derSignatureData = TWDataCreateWithNSData(derSignature)
        defer {
            TWDataDelete(derSignatureData)
        }
        guard let result = TWWebAuthnSolidityGetFormattedSignature(authenticatorDataString, clientDataJsonString, derSignatureData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }


}
