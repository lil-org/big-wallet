// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents a WalletConnect signing request.
public final class WalletConnectRequest {

    /// Parses the WalletConnect signing request as a `SigningInput`.
    ///
    /// - Parameter coin: The given coin type to plan the transaction for.
    /// - Parameter input: The serialized data of a `WalletConnect::Proto::ParseRequestInput` proto object.
    /// - Returns: The serialized data of `WalletConnect::Proto::ParseRequestOutput` proto object.
    public static func parse(coin: CoinType, input: Data) -> Data {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        return TWDataNSData(TWWalletConnectRequestParse(TWCoinType(rawValue: coin.rawValue), inputData))
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }


}
