// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public struct TransactionDecoder {

    /// Decodes a transaction from a binary representation.
    ///
    /// - Parameter coin: coin type.
    /// - Parameter encodedTx: encoded transaction data.
    /// - Returns: serialized protobuf message specific for the given coin.
    public static func decode(coinType: CoinType, encodedTx: Data) -> Data {
        let encodedTxData = TWDataCreateWithNSData(encodedTx)
        defer {
            TWDataDelete(encodedTxData)
        }
        return TWDataNSData(TWTransactionDecoderDecode(TWCoinType(rawValue: coinType.rawValue), encodedTxData))
    }


    init() {
    }


}
