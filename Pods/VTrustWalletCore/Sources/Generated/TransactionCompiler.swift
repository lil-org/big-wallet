// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Non-core transaction utility methods, like building a transaction using an external signature.
public struct TransactionCompiler {

    /// Obtains pre-signing hashes of a transaction.
    ///
    /// We provide a default `PreSigningOutput` in TransactionCompiler.proto. 
    /// For some special coins, such as bitcoin, we will create a custom `PreSigningOutput` object in its proto file.
    /// - Parameter coin: coin type.
    /// - Parameter txInputData: The serialized data of a signing input
    /// - Returns: serialized data of a proto object `PreSigningOutput` includes hash.
    public static func preImageHashes(coinType: CoinType, txInputData: Data) -> Data {
        let txInputDataData = TWDataCreateWithNSData(txInputData)
        defer {
            TWDataDelete(txInputDataData)
        }
        return TWDataNSData(TWTransactionCompilerPreImageHashes(TWCoinType(rawValue: coinType.rawValue), txInputDataData))
    }

    /// Compiles a complete transation with one or more external signatures.
    /// 
    /// Puts together from transaction input and provided public keys and signatures. The signatures must match the hashes
    /// returned by TWTransactionCompilerPreImageHashes, in the same order. The publicKeyHash attached
    /// to the hashes enable identifying the private key needed for signing the hash.
    /// - Parameter coin: coin type.
    /// - Parameter txInputData: The serialized data of a signing input.
    /// - Parameter signatures: signatures to compile, using TWDataVector.
    /// - Parameter publicKeys: public keys for signers to match private keys, using TWDataVector.
    /// - Returns: serialized data of a proto object `SigningOutput`.
    public static func compileWithSignatures(coinType: CoinType, txInputData: Data, signatures: DataVector, publicKeys: DataVector) -> Data {
        let txInputDataData = TWDataCreateWithNSData(txInputData)
        defer {
            TWDataDelete(txInputDataData)
        }
        return TWDataNSData(TWTransactionCompilerCompileWithSignatures(TWCoinType(rawValue: coinType.rawValue), txInputDataData, signatures.rawValue, publicKeys.rawValue))
    }


    public static func compileWithSignaturesAndPubKeyType(coinType: CoinType, txInputData: Data, signatures: DataVector, publicKeys: DataVector, pubKeyType: PublicKeyType) -> Data {
        let txInputDataData = TWDataCreateWithNSData(txInputData)
        defer {
            TWDataDelete(txInputDataData)
        }
        return TWDataNSData(TWTransactionCompilerCompileWithSignaturesAndPubKeyType(TWCoinType(rawValue: coinType.rawValue), txInputDataData, signatures.rawValue, publicKeys.rawValue, TWPublicKeyType(rawValue: pubKeyType.rawValue)))
    }


    init() {
    }


}
