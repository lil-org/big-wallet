// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public final class Eip7702 {

    /// Signs an Authorization hash in [EIP-7702 format](https://eips.ethereum.org/EIPS/eip-7702)
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
        guard let result = TWEip7702SignAuthorization(chainIdData, contractAddressString, nonceData, privateKeyString) else {
            return nil
        }
        return TWStringNSString(result)
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
        guard let result = TWEip7702GetAuthorizationHash(chainIdData, contractAddressString, nonceData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }


}
