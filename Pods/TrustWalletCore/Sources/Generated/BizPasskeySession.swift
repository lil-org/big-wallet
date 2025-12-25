// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public final class BizPasskeySession {

    /// Encodes `BizPasskeySession.registerSession` function call to register a session passkey public key.
    /// 
    /// - Parameter session_passkey_public_key: The nist256p1 (aka secp256p1) public key of the session passkey.
    /// - Parameter valid_until_timestamp: The timestamp until which the session is valid. Big endian uint64.
    /// - Returns: ABI-encoded function call.
    public static func encodeRegisterSessionCall(sessionPasskeyPublicKey: PublicKey, validUntilTimestamp: Data) -> Data? {
        let validUntilTimestampData = TWDataCreateWithNSData(validUntilTimestamp)
        defer {
            TWDataDelete(validUntilTimestampData)
        }
        guard let result = TWBizPasskeySessionEncodeRegisterSessionCall(sessionPasskeyPublicKey.rawValue, validUntilTimestampData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Encodes `BizPasskeySession.removeSession` function call to deregister a session passkey public key.
    /// 
    /// - Parameter session_passkey_public_key: The nist256p1 (aka secp256p1) public key of the session passkey.
    /// - Returns: ABI-encoded function call.
    public static func encodeRemoveSessionCall(sessionPasskeyPublicKey: PublicKey) -> Data? {
        guard let result = TWBizPasskeySessionEncodeRemoveSessionCall(sessionPasskeyPublicKey.rawValue) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Encodes `BizPasskeySession` nonce.
    /// 
    /// - Parameter nonce: The nonce of the Biz Passkey Session account.
    /// - Returns: uint256 represented as [passkey_nonce_key_192, nonce_64].
    public static func encodePasskeySessionNonce(nonce: Data) -> Data? {
        let nonceData = TWDataCreateWithNSData(nonce)
        defer {
            TWDataDelete(nonceData)
        }
        guard let result = TWBizPasskeySessionEncodePasskeySessionNonce(nonceData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Encodes `BizPasskeySession.executeWithPasskeySession` function call to execute a batch of transactions.
    /// 
    /// - Parameter input: The serialized data of `BizPasskeySession.ExecuteWithPasskeySessionInput` protobuf message.
    /// - Returns: ABI-encoded function call.
    public static func encodeExecuteWithPasskeySessionCall(input: Data) -> Data? {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        guard let result = TWBizPasskeySessionEncodeExecuteWithPasskeySessionCall(inputData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Signs and encodes `BizPasskeySession.executeWithPasskeySession` function call to execute a batch of transactions.
    /// 
    /// - Parameter input: The serialized data of `BizPasskeySession.ExecuteWithSignatureInput` protobuf message.
    /// - Returns: ABI-encoded function call.
    public static func signExecuteWithSignatureCall(input: Data) -> Data? {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        guard let result = TWBizPasskeySessionSignExecuteWithSignatureCall(inputData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }


}
