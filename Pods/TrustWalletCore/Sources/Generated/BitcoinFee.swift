// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public final class BitcoinFee {

    /// Calculates the fee of any Bitcoin transaction.
    ///
    /// - Parameter data:: the signed transaction in its final form.
    /// - Parameter satVb:: the satoshis per vbyte amount. The passed on string is interpreted as a unit64_t.
    /// - Returns:s the fee denominated in satoshis or nullptr if the transaction failed to be decoded.
    public static func calculateFee(data: Data, satVb: String) -> String? {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        let satVbString = TWStringCreateWithNSString(satVb)
        defer {
            TWStringDelete(satVbString)
        }
        guard let result = TWBitcoinFeeCalculateFee(dataData, satVbString) else {
            return nil
        }
        return TWStringNSString(result)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }


}
