// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// THORChain swap functions
public struct LiquidStaking {

    /// Builds a LiquidStaking transaction input.
    ///
    /// - Parameter input: The serialized data of LiquidStakingInput.
    /// - Returns: The serialized data of LiquidStakingOutput.
    public static func buildRequest(input: Data) -> Data {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        return TWDataNSData(TWLiquidStakingBuildRequest(inputData))
    }


    init() {
    }


}
