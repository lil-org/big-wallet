// Copyright © 2017-2020 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public struct EthereumFee {

    public static func suggest(feeHistory: String) -> String? {
        let feeHistoryString = TWStringCreateWithNSString(feeHistory)
        defer {
            TWStringDelete(feeHistoryString)
        }
        guard let result = TWEthereumFeeSuggest(feeHistoryString) else {
            return nil
        }
        return TWStringNSString(result)
    }


    init() {
    }


}
