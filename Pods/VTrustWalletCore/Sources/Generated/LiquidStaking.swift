// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
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
