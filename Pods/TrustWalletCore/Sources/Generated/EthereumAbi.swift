// Copyright © 2017-2020 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public struct EthereumAbi {

    public static func encode(fn: EthereumAbiFunction) -> Data {
        return TWDataNSData(TWEthereumAbiEncode(fn.rawValue))
    }

    public static func decodeOutput(fn: EthereumAbiFunction, encoded: Data) -> Bool {
        let encodedData = TWDataCreateWithNSData(encoded)
        defer {
            TWDataDelete(encodedData)
        }
        return TWEthereumAbiDecodeOutput(fn.rawValue, encodedData)
    }

    public static func decodeCall(data: Data, abi: String) -> String? {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        let abiString = TWStringCreateWithNSString(abi)
        defer {
            TWStringDelete(abiString)
        }
        guard let result = TWEthereumAbiDecodeCall(dataData, abiString) else {
            return nil
        }
        return TWStringNSString(result)
    }

    public static func encodeTyped(messageJson: String) -> Data {
        let messageJsonString = TWStringCreateWithNSString(messageJson)
        defer {
            TWStringDelete(messageJsonString)
        }
        return TWDataNSData(TWEthereumAbiEncodeTyped(messageJsonString))
    }


    init() {
    }


}
