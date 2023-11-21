// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Non-core transaction utility methods, like building a transaction using an external signature.
public struct TransactionCompiler {

    /// Builds a coin-specific SigningInput (proto object) from a simple transaction.
    ///
    /// \deprecated `TWTransactionCompilerBuildInput` will be removed soon.
    /// - Parameter coin: coin type.
    /// - Parameter from: sender of the transaction.
    /// - Parameter to: receiver of the transaction.
    /// - Parameter amount: transaction amount in string
    /// - Parameter asset: optional asset name, like "BNB"
    /// - Parameter memo: optional memo
    /// - Parameter chainId: optional chainId to override default
    /// - Returns: serialized data of the SigningInput proto object.
    public static func buildInput(coinType: CoinType, from: String, to: String, amount: String, asset: String, memo: String, chainId: String) -> Data {
        let fromString = TWStringCreateWithNSString(from)
        defer {
            TWStringDelete(fromString)
        }
        let toString = TWStringCreateWithNSString(to)
        defer {
            TWStringDelete(toString)
        }
        let amountString = TWStringCreateWithNSString(amount)
        defer {
            TWStringDelete(amountString)
        }
        let assetString = TWStringCreateWithNSString(asset)
        defer {
            TWStringDelete(assetString)
        }
        let memoString = TWStringCreateWithNSString(memo)
        defer {
            TWStringDelete(memoString)
        }
        let chainIdString = TWStringCreateWithNSString(chainId)
        defer {
            TWStringDelete(chainIdString)
        }
        return TWDataNSData(TWTransactionCompilerBuildInput(TWCoinType(rawValue: coinType.rawValue), fromString, toString, amountString, assetString, memoString, chainIdString))
    }

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
