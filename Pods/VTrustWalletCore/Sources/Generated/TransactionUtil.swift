// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public struct TransactionUtil {

    /// Calculate the TX hash of a transaction.
    ///
    /// - Parameter coin: coin type.
    /// - Parameter encodedTx: encoded transaction data.
    /// - Returns: The TX hash of a transaction, If the input is invalid or the chain is unsupported, null is returned.
    public static func calcTxHash(coinType: CoinType, encodedTx: String) -> String? {
        let encodedTxString = TWStringCreateWithNSString(encodedTx)
        defer {
            TWStringDelete(encodedTxString)
        }
        guard let result = TWTransactionUtilCalcTxHash(TWCoinType(rawValue: coinType.rawValue), encodedTxString) else {
            return nil
        }
        return TWStringNSString(result)
    }


    init() {
    }


}
