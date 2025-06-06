// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
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

    /// Returns the final hash to be signed by Barz for signing messages & typed data
    ///
    /// - Parameter msgHash: Original msgHash
    /// - Parameter barzAddress: The address of Barz wallet signing the message
    /// - Parameter chainId: The chainId of the network the verification will happen
    /// - Returns: The final hash to be signed
    public static func getPrefixedMsgHash(msgHash: Data, barzAddress: String, chainId: UInt32) -> Data {
        let msgHashData = TWDataCreateWithNSData(msgHash)
        defer {
            TWDataDelete(msgHashData)
        }
        let barzAddressString = TWStringCreateWithNSString(barzAddress)
        defer {
            TWStringDelete(barzAddressString)
        }
        return TWDataNSData(TWBarzGetPrefixedMsgHash(msgHashData, barzAddressString, chainId))
    }

    /// Returns the encoded diamondCut function call for Barz contract upgrades
    ///
    /// - Parameter input: The serialized data of DiamondCutInput
    /// - Returns: The encoded bytes of diamondCut function call
    public static func getDiamondCutCode(input: Data) -> Data {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        return TWDataNSData(TWBarzGetDiamondCutCode(inputData))
    }

    /// Computes an Authorization hash in [EIP-7702 format](https://eips.ethereum.org/EIPS/eip-7702)
    /// `keccak256('0x05' || rlp([chain_id, address, nonce]))`.
    ///
    /// - Parameter chainId: The chainId of the network
    /// - Parameter contractAddress: The address of the contract to be authorized
    /// - Parameter nonce: The nonce of the transaction
    /// - Returns: The authorization hash
    public static func getAuthorizationHash(chainId: Data, contractAddress: String, nonce: Data) -> Data {
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
        return TWDataNSData(TWBarzGetAuthorizationHash(chainIdData, contractAddressString, nonceData))
    }

    /// Returns the signed authorization hash
    ///
    /// - Parameter chainId: The chainId of the network
    /// - Parameter contractAddress: The address of the contract to be authorized
    /// - Parameter nonce: The nonce of the transaction
    /// - Parameter privateKey: The private key
    /// - Returns: A json string of the signed authorization
    public static func signAuthorization(chainId: Data, contractAddress: String, nonce: Data, privateKey: String) -> String {
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
        return TWStringNSString(TWBarzSignAuthorization(chainIdData, contractAddressString, nonceData, privateKeyString))
    }

    /// Returns the encoded hash of the user operation
    ///
    /// - Parameter chainId: The chainId of the network.
    /// - Parameter codeAddress: The address of the Biz Smart Contract.
    /// - Parameter codeName: The name of the Biz Smart Contract.
    /// - Parameter codeVersion: The version of the Biz Smart Contract.
    /// - Parameter typeHash: The type hash of the transaction.
    /// - Parameter domainSeparatorHash: The domain separator hash of the wallet.
    /// - Parameter sender: The address of the UserOperation sender.
    /// - Parameter userOpHash: The hash of the user operation.
    /// - Returns: The encoded hash of the user operation
    public static func getEncodedHash(chainId: Data, codeAddress: String, codeName: String, codeVersion: String, typeHash: String, domainSeparatorHash: String, sender: String, userOpHash: String) -> Data {
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
        return TWDataNSData(TWBarzGetEncodedHash(chainIdData, codeAddressString, codeNameString, codeVersionString, typeHashString, domainSeparatorHashString, senderString, userOpHashString))
    }

    /// Signs a message using the private key
    ///
    /// - Parameter hash: The hash to sign
    /// - Parameter privateKey: The private key
    /// - Returns: The signature
    public static func getSignedHash(hash: String, privateKey: String) -> Data {
        let hashString = TWStringCreateWithNSString(hash)
        defer {
            TWStringDelete(hashString)
        }
        let privateKeyString = TWStringCreateWithNSString(privateKey)
        defer {
            TWStringDelete(privateKeyString)
        }
        return TWDataNSData(TWBarzGetSignedHash(hashString, privateKeyString))
    }


    init() {
    }


}
