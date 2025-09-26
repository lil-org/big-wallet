// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public final class Barz {

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

    /// Returns the encoded hash of the user operation
    /// 
    /// - Parameter chain_id: The chain ID of the user.
    /// - Parameter code_address: The address of the smart contract wallet.
    /// - Parameter code_name: The name of the smart contract wallet.
    /// - Parameter code_version: The version of the smart contract wallet.
    /// - Parameter type_hash: The type hash of the smart contract wallet.
    /// - Parameter domain_separator_hash: The domain separator hash of the smart contract wallet.
    /// - Parameter sender: The sender of the smart contract wallet.
    /// - Parameter user_op_hash: The user operation hash of the smart contract wallet.
    /// - Returns: The encoded hash.
    public static func getEncodedHash(chainId: Data, codeAddress: String, codeName: String, codeVersion: String, typeHash: String, domainSeparatorHash: String, sender: String, userOpHash: String) -> Data? {
        let chainIdData = TWDataCreateWithNSData(chainId)
        defer {
            TWDataDelete(chainIdData)
        }
        let codeAddressString = TWStringCreateWithNSString(codeAddress)
        defer {
            TWStringDelete(codeAddressString)
        }
        let codeNameString = TWStringCreateWithNSString(codeName)
        defer {
            TWStringDelete(codeNameString)
        }
        let codeVersionString = TWStringCreateWithNSString(codeVersion)
        defer {
            TWStringDelete(codeVersionString)
        }
        let typeHashString = TWStringCreateWithNSString(typeHash)
        defer {
            TWStringDelete(typeHashString)
        }
        let domainSeparatorHashString = TWStringCreateWithNSString(domainSeparatorHash)
        defer {
            TWStringDelete(domainSeparatorHashString)
        }
        let senderString = TWStringCreateWithNSString(sender)
        defer {
            TWStringDelete(senderString)
        }
        let userOpHashString = TWStringCreateWithNSString(userOpHash)
        defer {
            TWStringDelete(userOpHashString)
        }
        guard let result = TWBarzGetEncodedHash(chainIdData, codeAddressString, codeNameString, codeVersionString, typeHashString, domainSeparatorHashString, senderString, userOpHashString) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Signs a message using the private key
    /// 
    /// - Parameter hash: The hash of the user.
    /// - Parameter private_key: The private key of the user.
    /// - Returns: The signed hash.
    public static func getSignedHash(hash: String, privateKey: String) -> Data? {
        let hashString = TWStringCreateWithNSString(hash)
        defer {
            TWStringDelete(hashString)
        }
        let privateKeyString = TWStringCreateWithNSString(privateKey)
        defer {
            TWStringDelete(privateKeyString)
        }
        guard let result = TWBarzGetSignedHash(hashString, privateKeyString) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Computes an Authorization hash in [EIP-7702 format](https://eips.ethereum.org/EIPS/eip-7702)
    /// `keccak256('0x05' || rlp([chain_id, address, nonce]))`.
    /// 
    /// - Parameter chain_id: The chain ID of the user.
    /// - Parameter contract_address: The address of the smart contract wallet.
    /// - Parameter nonce: The nonce of the user.
    /// - Returns: The authorization hash.
    public static func getAuthorizationHash(chainId: Data, contractAddress: String, nonce: Data) -> Data? {
        let chainIdData = TWDataCreateWithNSData(chainId)
        defer {
            TWDataDelete(chainIdData)
        }
        let contractAddressString = TWStringCreateWithNSString(contractAddress)
        defer {
            TWStringDelete(contractAddressString)
        }
        let nonceData = TWDataCreateWithNSData(nonce)
        defer {
            TWDataDelete(nonceData)
        }
        guard let result = TWBarzGetAuthorizationHash(chainIdData, contractAddressString, nonceData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Returns the signed authorization hash
    /// 
    /// - Parameter chain_id: The chain ID of the user.
    /// - Parameter contract_address: The address of the smart contract wallet.
    /// - Parameter nonce: The nonce of the user.
    /// - Parameter private_key: The private key of the user.
    /// - Returns: The signed authorization.
    public static func signAuthorization(chainId: Data, contractAddress: String, nonce: Data, privateKey: String) -> String? {
        let chainIdData = TWDataCreateWithNSData(chainId)
        defer {
            TWDataDelete(chainIdData)
        }
        let contractAddressString = TWStringCreateWithNSString(contractAddress)
        defer {
            TWStringDelete(contractAddressString)
        }
        let nonceData = TWDataCreateWithNSData(nonce)
        defer {
            TWDataDelete(nonceData)
        }
        let privateKeyString = TWStringCreateWithNSString(privateKey)
        defer {
            TWStringDelete(privateKeyString)
        }
        guard let result = TWBarzSignAuthorization(chainIdData, contractAddressString, nonceData, privateKeyString) else {
            return nil
        }
        return TWStringNSString(result)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }


}
