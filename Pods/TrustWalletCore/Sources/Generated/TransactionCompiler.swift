// Copyright © 2017-2022 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public struct TransactionCompiler {

    public static func buildInput(coinType: CoinType, from: String, to: String, amount: String, asset: String, memo: String, chainId: String) -> Data {
        let fromString = TWStringCreateWithNSString(from)
        defer {
            TWStringDelete(fromString)
        }
        let toString = TWStringCreateWithNSString(to)
        defer {
            TWStringDelete(toString)
        }
        let amountString = TWStringCreateWithNSString(amount)
        defer {
            TWStringDelete(amountString)
        }
        let assetString = TWStringCreateWithNSString(asset)
        defer {
            TWStringDelete(assetString)
        }
        let memoString = TWStringCreateWithNSString(memo)
        defer {
            TWStringDelete(memoString)
        }
        let chainIdString = TWStringCreateWithNSString(chainId)
        defer {
            TWStringDelete(chainIdString)
        }
        return TWDataNSData(TWTransactionCompilerBuildInput(TWCoinType(rawValue: coinType.rawValue), fromString, toString, amountString, assetString, memoString, chainIdString))
    }

    public static func preImageHashes(coinType: CoinType, txInputData: Data) -> Data {
        let txInputDataData = TWDataCreateWithNSData(txInputData)
        defer {
            TWDataDelete(txInputDataData)
        }
        return TWDataNSData(TWTransactionCompilerPreImageHashes(TWCoinType(rawValue: coinType.rawValue), txInputDataData))
    }

    public static func compileWithSignatures(coinType: CoinType, txInputData: Data, signatures: DataVector, publicKeys: DataVector) -> Data {
        let txInputDataData = TWDataCreateWithNSData(txInputData)
        defer {
            TWDataDelete(txInputDataData)
        }
        return TWDataNSData(TWTransactionCompilerCompileWithSignatures(TWCoinType(rawValue: coinType.rawValue), txInputDataData, signatures.rawValue, publicKeys.rawValue))
    }


    init() {
    }


}
