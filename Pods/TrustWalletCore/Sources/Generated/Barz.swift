// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public final class Barz {

    /// Converts the original ASN-encoded signature from webauthn to the format accepted by Barz
    /// 
    /// - Parameter signature: Original signature
    /// - Parameter challenge: The original challenge that was signed
    /// - Parameter authenticator_data: Returned from Webauthn API
    /// - Parameter client_data_json: Returned from Webauthn API
    /// - Returns: Bytes of the formatted signature
    public static func getFormattedSignature(signature: Data, challenge: Data, authenticatorData: Data, clientDataJson: String) -> Data? {
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
        let clientDataJsonString = TWStringCreateWithNSString(clientDataJson)
        defer {
            TWStringDelete(clientDataJsonString)
        }
        guard let result = TWBarzGetFormattedSignature(signatureData, challengeData, authenticatorDataData, clientDataJsonString) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Returns the final hash to be signed by Barz for signing messages & typed data
    /// 
    /// - Parameter msg_hash: Original msgHash
    /// - Parameter barzAddress: The address of Barz wallet signing the message
    /// - Parameter chainId: The chainId of the network the verification will happen; Must be non-negative
    /// - Returns: The final hash to be signed.
    public static func getPrefixedMsgHash(msgHash: Data, barzAddress: String, chainId: Int32) -> Data? {
        let msgHashData = TWDataCreateWithNSData(msgHash)
        defer {
            TWDataDelete(msgHashData)
        }
        let barzAddressString = TWStringCreateWithNSString(barzAddress)
        defer {
            TWStringDelete(barzAddressString)
        }
        guard let result = TWBarzGetPrefixedMsgHash(msgHashData, barzAddressString, chainId) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Returns the encoded diamondCut function call for Barz contract upgrades
    /// 
    /// - Parameter input: The serialized data of DiamondCutInput.
    /// - Returns: The diamond cut code.
    public static func getDiamondCutCode(input: Data) -> Data? {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        guard let result = TWBarzGetDiamondCutCode(inputData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Calculate a counterfactual address for the smart contract wallet
    /// 
    /// - Parameter input: The serialized data of ContractAddressInput.
    /// - Returns: The address.
    public static func getCounterfactualAddress(input: Data) -> String? {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        guard let result = TWBarzGetCounterfactualAddress(inputData) else {
            return nil
        }
        return TWStringNSString(result)
    }

    /// Returns the init code parameter of ERC-4337 User Operation
    /// 
    /// - Parameter factory: The address of the factory contract
    /// - Parameter public_key: Public key for the verification facet
    /// - Parameter verification_facet: The address of the verification facet
    /// - Parameter salt: The salt of the init code; Must be non-negative
    /// - Returns: The init code.
    public static func getInitCode(factory: String, publicKey: PublicKey, verificationFacet: String, salt: Int32) -> Data? {
        let factoryString = TWStringCreateWithNSString(factory)
        defer {
            TWStringDelete(factoryString)
        }
        let verificationFacetString = TWStringCreateWithNSString(verificationFacet)
        defer {
            TWStringDelete(verificationFacetString)
        }
        guard let result = TWBarzGetInitCode(factoryString, publicKey.rawValue, verificationFacetString, salt) else {
            return nil
        }
        return TWDataNSData(result)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }


}
