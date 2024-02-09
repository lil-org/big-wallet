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


    init() {
    }


}
