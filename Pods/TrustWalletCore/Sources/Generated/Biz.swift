// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public final class Biz {

    /// Encodes `Biz.executeWithPasskeySession` function call to execute a batch of transactions.
    /// 
    /// - Parameter input: The serialized data of `Biz.ExecuteWithPasskeySessionInput` protobuf message.
    /// - Returns: ABI-encoded function call.
    public static func encodeExecuteWithPasskeySessionCall(input: Data) -> Data? {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        guard let result = TWBizEncodeExecuteWithPasskeySessionCall(inputData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Encodes `Biz.registerSession` function call to register a session passkey public key.
    /// 
    /// - Parameter session_passkey_public_key: The nist256p1 (aka secp256p1) public key of the session passkey.
    /// - Parameter valid_until_timestamp: The timestamp until which the session is valid. Big endian uint64.
    /// - Returns: ABI-encoded function call.
    public static func encodeRegisterSessionCall(sessionPasskeyPublicKey: PublicKey, validUntilTimestamp: Data) -> Data? {
        let validUntilTimestampData = TWDataCreateWithNSData(validUntilTimestamp)
        defer {
            TWDataDelete(validUntilTimestampData)
        }
        guard let result = TWBizEncodeRegisterSessionCall(sessionPasskeyPublicKey.rawValue, validUntilTimestampData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Encodes `Biz.removeSession` function call to deregister a session passkey public key.
    /// 
    /// - Parameter session_passkey_public_key: The nist256p1 (aka secp256p1) public key of the session passkey.
    /// - Returns: ABI-encoded function call.
    public static func encodeRemoveSessionCall(sessionPasskeyPublicKey: PublicKey) -> Data? {
        guard let result = TWBizEncodeRemoveSessionCall(sessionPasskeyPublicKey.rawValue) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Encodes Biz Passkey Session nonce.
    /// 
    /// - Parameter nonce: The nonce of the Biz Passkey Session account.
    /// - Returns: uint256 represented as [passkey_nonce_key_192, nonce_64].
    public static func encodePasskeySessionNonce(nonce: Data) -> Data? {
        let nonceData = TWDataCreateWithNSData(nonce)
        defer {
            TWDataDelete(nonceData)
        }
        guard let result = TWBizEncodePasskeySessionNonce(nonceData) else {
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
        guard let result = TWBizGetEncodedHash(chainIdData, codeAddressString, codeNameString, codeVersionString, typeHashString, domainSeparatorHashString, senderString, userOpHashString) else {
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
        guard let result = TWBizGetSignedHash(hashString, privateKeyString) else {
            return nil
        }
        return TWDataNSData(result)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }


}
