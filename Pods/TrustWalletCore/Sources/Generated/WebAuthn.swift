// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public struct WebAuthn {

    /// Converts attestation object to the public key on P256 curve
    ///
    /// - Parameter attestationObject: Attestation object retrieved from webuthn.get method
    /// - Returns: Public key.
    public static func getPublicKey(attestationObject: Data) -> PublicKey? {
        let attestationObjectData = TWDataCreateWithNSData(attestationObject)
        defer {
            TWDataDelete(attestationObjectData)
        }
        guard let value = TWWebAuthnGetPublicKey(attestationObjectData) else {
            return nil
        }
        return PublicKey(rawValue: value)
    }

    /// Uses ASN parser to extract r and s values from a webauthn signature
    ///
    /// - Parameter signature: ASN encoded webauthn signature: https://www.w3.org/TR/webauthn-2/#sctn-signature-attestation-types
    /// - Returns: Concatenated r and s values.
    public static func getRSValues(signature: Data) -> Data {
        let signatureData = TWDataCreateWithNSData(signature)
        defer {
            TWDataDelete(signatureData)
        }
        return TWDataNSData(TWWebAuthnGetRSValues(signatureData))
    }

    /// Reconstructs the original message that was signed via P256 curve. Can be used for signature validation.
    ///
    /// - Parameter authenticatorData: Authenticator Data: https://www.w3.org/TR/webauthn-2/#authenticator-data
    /// - Parameter clientDataJSON: clientDataJSON: https://www.w3.org/TR/webauthn-2/#dom-authenticatorresponse-clientdatajson
    /// - Returns: original messages.
    public static func reconstructOriginalMessage(authenticatorData: Data, clientDataJSON: Data) -> Data {
        let authenticatorDataData = TWDataCreateWithNSData(authenticatorData)
        defer {
            TWDataDelete(authenticatorDataData)
        }
        let clientDataJSONData = TWDataCreateWithNSData(clientDataJSON)
        defer {
            TWDataDelete(clientDataJSONData)
        }
        return TWDataNSData(TWWebAuthnReconstructOriginalMessage(authenticatorDataData, clientDataJSONData))
    }


    init() {
    }


}
