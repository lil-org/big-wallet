// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// THORChain swap functions
public struct THORChainSwap {

    /// Builds a THORChainSwap transaction input.
    ///
    /// - Parameter input: The serialized data of SwapInput.
    /// - Returns: The serialized data of SwapOutput.
    public static func buildSwap(input: Data) -> Data {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        return TWDataNSData(TWTHORChainSwapBuildSwap(inputData))
    }


    init() {
    }


}
