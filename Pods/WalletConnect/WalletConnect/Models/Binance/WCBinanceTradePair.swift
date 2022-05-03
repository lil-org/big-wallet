// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation

public struct WCBinanceTradePair {
    public let from: String
    public let to: String

    public static func from(_ symbol: String) -> WCBinanceTradePair? {
        let pair = symbol.split(separator: "_")
        guard pair.count > 1 else { return nil }
        let first_parts = pair[0].split(separator: "-")
        let second_parts = pair[1].split(separator: "-")
        return WCBinanceTradePair(from: String(first_parts[0]), to: String(second_parts[0]))
    }
}
