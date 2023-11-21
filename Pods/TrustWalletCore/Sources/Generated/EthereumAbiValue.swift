// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents Ethereum ABI value
public struct EthereumAbiValue {

    /// Encode a bool according to Ethereum ABI, into 32 bytes.  Values are padded by 0 on the left, unless specified otherwise
    ///
    /// - Parameter value: a boolean value
    /// - Returns: Encoded value stored in a block of data
    public static func encodeBool(value: Bool) -> Data {
        return TWDataNSData(TWEthereumAbiValueEncodeBool(value))
    }

    /// Encode a int32 according to Ethereum ABI, into 32 bytes. Values are padded by 0 on the left, unless specified otherwise
    ///
    /// - Parameter value: a int32 value
    /// - Returns: Encoded value stored in a block of data
    public static func encodeInt32(value: Int32) -> Data {
        return TWDataNSData(TWEthereumAbiValueEncodeInt32(value))
    }

    /// Encode a uint32 according to Ethereum ABI, into 32 bytes.  Values are padded by 0 on the left, unless specified otherwise
    ///
    /// - Parameter value: a uint32 value
    /// - Returns: Encoded value stored in a block of data
    public static func encodeUInt32(value: UInt32) -> Data {
        return TWDataNSData(TWEthereumAbiValueEncodeUInt32(value))
    }

    /// Encode a int256 according to Ethereum ABI, into 32 bytes.  Values are padded by 0 on the left, unless specified otherwise
    ///
    /// - Parameter value: a int256 value stored in a block of data
    /// - Returns: Encoded value stored in a block of data
    public static func encodeInt256(value: Data) -> Data {
        let valueData = TWDataCreateWithNSData(value)
        defer {
            TWDataDelete(valueData)
        }
        return TWDataNSData(TWEthereumAbiValueEncodeInt256(valueData))
    }

    /// Encode an int256 according to Ethereum ABI, into 32 bytes.  Values are padded by 0 on the left, unless specified otherwise
    ///
    /// - Parameter value: a int256 value stored in a block of data
    /// - Returns: Encoded value stored in a block of data
    public static func encodeUInt256(value: Data) -> Data {
        let valueData = TWDataCreateWithNSData(value)
        defer {
            TWDataDelete(valueData)
        }
        return TWDataNSData(TWEthereumAbiValueEncodeUInt256(valueData))
    }

    /// Encode an address according to Ethereum ABI, 20 bytes of the address.
    ///
    /// - Parameter value: an address value stored in a block of data
    /// - Returns: Encoded value stored in a block of data
    public static func encodeAddress(value: Data) -> Data {
        let valueData = TWDataCreateWithNSData(value)
        defer {
            TWDataDelete(valueData)
        }
        return TWDataNSData(TWEthereumAbiValueEncodeAddress(valueData))
    }

    /// Encode a string according to Ethereum ABI by encoding its hash.
    ///
    /// - Parameter value: a string value
    /// - Returns: Encoded value stored in a block of data
    public static func encodeString(value: String) -> Data {
        let valueString = TWStringCreateWithNSString(value)
        defer {
            TWStringDelete(valueString)
        }
        return TWDataNSData(TWEthereumAbiValueEncodeString(valueString))
    }

    /// Encode a number of bytes, up to 32 bytes, padded on the right.  Longer arrays are truncated.
    ///
    /// - Parameter value: bunch of bytes
    /// - Returns: Encoded value stored in a block of data
    public static func encodeBytes(value: Data) -> Data {
        let valueData = TWDataCreateWithNSData(value)
        defer {
            TWDataDelete(valueData)
        }
        return TWDataNSData(TWEthereumAbiValueEncodeBytes(valueData))
    }

    /// Encode a dynamic number of bytes by encoding its hash
    ///
    /// - Parameter value: bunch of bytes
    /// - Returns: Encoded value stored in a block of data
    public static func encodeBytesDyn(value: Data) -> Data {
        let valueData = TWDataCreateWithNSData(value)
        defer {
            TWDataDelete(valueData)
        }
        return TWDataNSData(TWEthereumAbiValueEncodeBytesDyn(valueData))
    }

    /// Decodes input data (bytes longer than 32 will be truncated) as uint256
    ///
    /// - Parameter input: Data to be decoded
    /// - Returns: Non-null decoded string value
    public static func decodeUInt256(input: Data) -> String {
        let inputData = TWDataCreateWithNSData(input)
        defer {
            TWDataDelete(inputData)
        }
        return TWStringNSString(TWEthereumAbiValueDecodeUInt256(inputData))
    }

    /// Decode an arbitrary type, return value as string
    ///
    /// - Parameter input: Data to be decoded
    /// - Parameter type: the underlying type that need to be decoded
    /// - Returns: Non-null decoded string value
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

    /// Decode an array of given simple types.  Return a '\n'-separated string of elements
    ///
    /// - Parameter input: Data to be decoded
    /// - Parameter type: the underlying type that need to be decoded
    /// - Returns: Non-null decoded string value
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
