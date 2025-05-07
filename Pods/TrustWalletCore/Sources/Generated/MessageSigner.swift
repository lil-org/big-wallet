// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public final class MessageSigner {

    /// Verifies a signature for a message.
    /// 
    /// - Parameter coin: The given coin type to sign the message for.
    /// - Parameter input: The serialized data of a verifying input (e.g. TW.Ethereum.Proto.MessageVerifyingInput).
    /// - Returns: whether the signature is valid.
    public static func verify(coin: CoinType, input: Data) -> Bool {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        return TWMessageSignerVerify(TWCoinType(rawValue: coin.rawValue), inputData)
    }

    /// Computes preimage hashes of a message.
    /// 
    /// - Parameter coin: The given coin type to sign the message for.
    /// - Parameter input: The serialized data of a signing input (e.g. TW.Ethereum.Proto.MessageSigningInput).
    /// - Returns: The serialized data of TW.TxCompiler.PreSigningOutput.
    public static func preImageHashes(coin: CoinType, input: Data) -> Data? {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        guard let result = TWMessageSignerPreImageHashes(TWCoinType(rawValue: coin.rawValue), inputData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Signs an arbitrary message to prove ownership of an address for off-chain services.
    /// 
    /// - Parameter coin: The given coin type to sign the message for.
    /// - Parameter input: The serialized data of a signing input (e.g. TW.Ethereum.Proto.MessageSigningInput).
    /// - Returns: The serialized data of a `SigningOutput` proto object. (e.g. TW.Ethereum.Proto.MessageSigningOutput).
    public static func sign(coin: CoinType, input: Data) -> Data? {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        guard let result = TWMessageSignerSign(TWCoinType(rawValue: coin.rawValue), inputData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }


}
