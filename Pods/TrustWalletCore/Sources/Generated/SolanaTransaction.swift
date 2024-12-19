// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public struct SolanaTransaction {

    /// Decode Solana transaction, update the recent blockhash and re-sign the transaction.
    ///
    /// # Warning
    ///
    /// This is a temporary solution. It will be removed when `Solana.proto` supports
    /// direct transaction signing.
    ///
    /// - Parameter encodedTx: base64 encoded Solana transaction.
    /// - Parameter recentBlockhash: base58 encoded recent blockhash.
    /// - Parameter privateKeys: list of private keys that should be used to re-sign the transaction.
    /// - Returns: serialized `Solana::Proto::SigningOutput`.
    public static func updateBlockhashAndSign(encodedTx: String, recentBlockhash: String, privateKeys: DataVector) -> Data {
        let encodedTxString = TWStringCreateWithNSString(encodedTx)
        defer {
            TWStringDelete(encodedTxString)
        }
        let recentBlockhashString = TWStringCreateWithNSString(recentBlockhash)
        defer {
            TWStringDelete(recentBlockhashString)
        }
        return TWDataNSData(TWSolanaTransactionUpdateBlockhashAndSign(encodedTxString, recentBlockhashString, privateKeys.rawValue))
    }

    /// Try to find a `ComputeBudgetInstruction::SetComputeUnitPrice` instruction in the given transaction,
    /// and returns the specified Unit Price.
    ///
    /// - Parameter encodedTx: base64 encoded Solana transaction.
    /// - Returns: nullable Unit Price as a decimal string. Null if no instruction found.
    public static func getComputeUnitPrice(encodedTx: String) -> String? {
        let encodedTxString = TWStringCreateWithNSString(encodedTx)
        defer {
            TWStringDelete(encodedTxString)
        }
        guard let result = TWSolanaTransactionGetComputeUnitPrice(encodedTxString) else {
            return nil
        }
        return TWStringNSString(result)
    }

    /// Try to find a `ComputeBudgetInstruction::SetComputeUnitLimit` instruction in the given transaction,
    /// and returns the specified Unit Limit.
    ///
    /// - Parameter encodedTx: base64 encoded Solana transaction.
    /// - Returns: nullable Unit Limit as a decimal string. Null if no instruction found.
    public static func getComputeUnitLimit(encodedTx: String) -> String? {
        let encodedTxString = TWStringCreateWithNSString(encodedTx)
        defer {
            TWStringDelete(encodedTxString)
        }
        guard let result = TWSolanaTransactionGetComputeUnitLimit(encodedTxString) else {
            return nil
        }
        return TWStringNSString(result)
    }

    /// Adds or updates a `ComputeBudgetInstruction::SetComputeUnitPrice` instruction of the given transaction,
    /// and returns the updated transaction.
    ///
    /// - Parameter encodedTx: base64 encoded Solana transaction.
    /// - Parameter price: Unit Price as a decimal string.
    /// - Returns: base64 encoded Solana transaction. Null if an error occurred.
    public static func setComputeUnitPrice(encodedTx: String, price: String) -> String? {
        let encodedTxString = TWStringCreateWithNSString(encodedTx)
        defer {
            TWStringDelete(encodedTxString)
        }
        let priceString = TWStringCreateWithNSString(price)
        defer {
            TWStringDelete(priceString)
        }
        guard let result = TWSolanaTransactionSetComputeUnitPrice(encodedTxString, priceString) else {
            return nil
        }
        return TWStringNSString(result)
    }

    /// Adds or updates a `ComputeBudgetInstruction::SetComputeUnitLimit` instruction of the given transaction,
    /// and returns the updated transaction.
    ///
    /// - Parameter encodedTx: base64 encoded Solana transaction.
    /// - Parameter limit: Unit Limit as a decimal string.
    /// - Returns: base64 encoded Solana transaction. Null if an error occurred.
    public static func setComputeUnitLimit(encodedTx: String, limit: String) -> String? {
        let encodedTxString = TWStringCreateWithNSString(encodedTx)
        defer {
            TWStringDelete(encodedTxString)
        }
        let limitString = TWStringCreateWithNSString(limit)
        defer {
            TWStringDelete(limitString)
        }
        guard let result = TWSolanaTransactionSetComputeUnitLimit(encodedTxString, limitString) else {
            return nil
        }
        return TWStringNSString(result)
    }

    /// Adds fee payer to the given transaction and returns the updated transaction.
    ///
    /// - Parameter encodedTx: base64 encoded Solana transaction.
    /// - Parameter feePayer: fee payer account address. Must be a base58 encoded public key. It must NOT be in the account list yet.
    /// - Returns: base64 encoded Solana transaction. Null if an error occurred.
    public static func setFeePayer(encodedTx: String, feePayer: String) -> String? {
        let encodedTxString = TWStringCreateWithNSString(encodedTx)
        defer {
            TWStringDelete(encodedTxString)
        }
        let feePayerString = TWStringCreateWithNSString(feePayer)
        defer {
            TWStringDelete(feePayerString)
        }
        guard let result = TWSolanaTransactionSetFeePayer(encodedTxString, feePayerString) else {
            return nil
        }
        return TWStringNSString(result)
    }


    init() {
    }


}
