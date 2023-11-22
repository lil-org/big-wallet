// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Barz functions
public struct Barz {

    /// Calculate a counterfactual address for the smart contract wallet
    ///
    /// - Parameter input: The serialized data of ContractAddressInput.
    /// - Returns: The address.
    public static func getCounterfactualAddress(input: Data) -> String {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        return TWStringNSString(TWBarzGetCounterfactualAddress(inputData))
    }

    /// Returns the init code parameter of ERC-4337 User Operation
    ///
    /// - Parameter factory: Wallet factory address (BarzFactory)
    /// - Parameter publicKey: Public key for the verification facet
    /// - Parameter verificationFacet: Verification facet address
    /// - Returns: The address.
    public static func getInitCode(factory: String, publicKey: PublicKey, verificationFacet: String, salt: UInt32) -> Data {
        let factoryString = TWStringCreateWithNSString(factory)
        defer {
            TWStringDelete(factoryString)
        }
        let verificationFacetString = TWStringCreateWithNSString(verificationFacet)
        defer {
            TWStringDelete(verificationFacetString)
        }
        return TWDataNSData(TWBarzGetInitCode(factoryString, publicKey.rawValue, verificationFacetString, salt))
    }

    /// Converts the original ASN-encoded signature from webauthn to the format accepted by Barz
    ///
    /// - Parameter signature: Original signature
    /// - Parameter challenge: The original challenge that was signed
    /// - Parameter authenticatorData: Returned from Webauthn API
    /// - Parameter clientDataJSON: Returned from Webauthn API
    /// - Returns: Bytes of the formatted signature
    public static func getFormattedSignature(signature: Data, challenge: Data, authenticatorData: Data, clientDataJSON: String) -> Data {
        let signatureData = TWDataCreateWithNSData(signature)
        defer {
            TWDataDelete(signatureData)
        }
        let challengeData = TWDataCreateWithNSData(challenge)
        defer {
            TWDataDelete(challengeData)
        }
        let authenticatorDataData = TWDataCreateWithNSData(authenticatorData)
        defer {
            TWDataDelete(authenticatorDataData)
        }
        let clientDataJSONString = TWStringCreateWithNSString(clientDataJSON)
        defer {
            TWStringDelete(clientDataJSONString)
        }
        return TWDataNSData(TWBarzGetFormattedSignature(signatureData, challengeData, authenticatorDataData, clientDataJSONString))
    }


    init() {
    }


}
