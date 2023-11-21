// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public struct EthereumRlp {

    /// Encode an item or a list of items as Eth RLP binary format.
    ///
    /// - Parameter coin: EVM-compatible coin type.
    /// - Parameter input: Non-null serialized `EthereumRlp::Proto::EncodingInput`.
    /// - Returns: serialized `EthereumRlp::Proto::EncodingOutput`.
    public static func encode(coin: CoinType, input: Data) -> Data {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        return TWDataNSData(TWEthereumRlpEncode(TWCoinType(rawValue: coin.rawValue), inputData))
    }


    init() {
    }


}
