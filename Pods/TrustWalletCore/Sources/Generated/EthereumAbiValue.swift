// Copyright © 2017-2020 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public struct EthereumAbiValue {

    public static func encodeBool(value: Bool) -> Data {
        return TWDataNSData(TWEthereumAbiValueEncodeBool(value))
    }

    public static func encodeInt32(value: Int32) -> Data {
        return TWDataNSData(TWEthereumAbiValueEncodeInt32(value))
    }

    public static func encodeUInt32(value: UInt32) -> Data {
        return TWDataNSData(TWEthereumAbiValueEncodeUInt32(value))
    }

    public static func encodeInt256(value: Data) -> Data {
        let valueData = TWDataCreateWithNSData(value)
        defer {
            TWDataDelete(valueData)
        }
        return TWDataNSData(TWEthereumAbiValueEncodeInt256(valueData))
    }

    public static func encodeUInt256(value: Data) -> Data {
        let valueData = TWDataCreateWithNSData(value)
        defer {
            TWDataDelete(valueData)
        }
        return TWDataNSData(TWEthereumAbiValueEncodeUInt256(valueData))
    }

    public static func encodeAddress(value: Data) -> Data {
        let valueData = TWDataCreateWithNSData(value)
        defer {
            TWDataDelete(valueData)
        }
        return TWDataNSData(TWEthereumAbiValueEncodeAddress(valueData))
    }

    public static func encodeString(value: String) -> Data {
        let valueString = TWStringCreateWithNSString(value)
        defer {
            TWStringDelete(valueString)
        }
        return TWDataNSData(TWEthereumAbiValueEncodeString(valueString))
    }

    public static func encodeBytes(value: Data) -> Data {
        let valueData = TWDataCreateWithNSData(value)
        defer {
            TWDataDelete(valueData)
        }
        return TWDataNSData(TWEthereumAbiValueEncodeBytes(valueData))
    }

    public static func encodeBytesDyn(value: Data) -> Data {
        let valueData = TWDataCreateWithNSData(value)
        defer {
            TWDataDelete(valueData)
        }
        return TWDataNSData(TWEthereumAbiValueEncodeBytesDyn(valueData))
    }

    public static func decodeUInt256(input: Data) -> String {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        return TWStringNSString(TWEthereumAbiValueDecodeUInt256(inputData))
    }

    public static func decodeValue(input: Data, type: String) -> String {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        let typeString = TWStringCreateWithNSString(type)
        defer {
            TWStringDelete(typeString)
        }
        return TWStringNSString(TWEthereumAbiValueDecodeValue(inputData, typeString))
    }

    public static func decodeArray(input: Data, type: String) -> String {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        let typeString = TWStringCreateWithNSString(type)
        defer {
            TWStringDelete(typeString)
        }
        return TWStringNSString(TWEthereumAbiValueDecodeArray(inputData, typeString))
    }


    init() {
    }


}
