// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents Ethereum ABI function
public final class EthereumAbiFunction {

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init(name: String) {
        let nameString = TWStringCreateWithNSString(name)
        defer {
            TWStringDelete(nameString)
        }
        rawValue = TWEthereumAbiFunctionCreateWithString(nameString)
    }

    deinit {
        TWEthereumAbiFunctionDelete(rawValue)
    }

    /// Return the function type signature, of the form "baz(int32,uint256)"
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Returns: function type signature as a Non-null string.
    public func getType() -> String {
        return TWStringNSString(TWEthereumAbiFunctionGetType(rawValue))
    }

    /// Methods for adding parameters of the given type (input or output).
    /// For output parameters (isOutput=true) a value has to be specified, although usually not need;
    /// Add a uint8 type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamUInt8(val: UInt8, isOutput: Bool) -> Int32 {
        return TWEthereumAbiFunctionAddParamUInt8(rawValue, val, isOutput)
    }

    /// Add a uint16 type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamUInt16(val: UInt16, isOutput: Bool) -> Int32 {
        return TWEthereumAbiFunctionAddParamUInt16(rawValue, val, isOutput)
    }

    /// Add a uint32 type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamUInt32(val: UInt32, isOutput: Bool) -> Int32 {
        return TWEthereumAbiFunctionAddParamUInt32(rawValue, val, isOutput)
    }

    /// Add a uint64 type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamUInt64(val: UInt64, isOutput: Bool) -> Int32 {
        return TWEthereumAbiFunctionAddParamUInt64(rawValue, val, isOutput)
    }

    /// Add a uint256 type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamUInt256(val: Data, isOutput: Bool) -> Int32 {
        let valData = TWDataCreateWithNSData(val)
        defer {
            TWDataDelete(valData)
        }
        return TWEthereumAbiFunctionAddParamUInt256(rawValue, valData, isOutput)
    }

    /// Add a uint(bits) type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamUIntN(bits: Int32, val: Data, isOutput: Bool) -> Int32 {
        let valData = TWDataCreateWithNSData(val)
        defer {
            TWDataDelete(valData)
        }
        return TWEthereumAbiFunctionAddParamUIntN(rawValue, Int32(bits), valData, isOutput)
    }

    /// Add a int8 type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamInt8(val: Int8, isOutput: Bool) -> Int32 {
        return TWEthereumAbiFunctionAddParamInt8(rawValue, val, isOutput)
    }

    /// Add a int16 type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamInt16(val: Int16, isOutput: Bool) -> Int32 {
        return TWEthereumAbiFunctionAddParamInt16(rawValue, val, isOutput)
    }

    /// Add a int32 type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamInt32(val: Int32, isOutput: Bool) -> Int32 {
        return TWEthereumAbiFunctionAddParamInt32(rawValue, val, isOutput)
    }

    /// Add a int64 type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamInt64(val: Int64, isOutput: Bool) -> Int32 {
        return TWEthereumAbiFunctionAddParamInt64(rawValue, val, isOutput)
    }

    /// Add a int256 type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified (stored in a block of data)
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamInt256(val: Data, isOutput: Bool) -> Int32 {
        let valData = TWDataCreateWithNSData(val)
        defer {
            TWDataDelete(valData)
        }
        return TWEthereumAbiFunctionAddParamInt256(rawValue, valData, isOutput)
    }

    /// Add a int(bits) type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter bits: Number of bits of the integer parameter
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamIntN(bits: Int32, val: Data, isOutput: Bool) -> Int32 {
        let valData = TWDataCreateWithNSData(val)
        defer {
            TWDataDelete(valData)
        }
        return TWEthereumAbiFunctionAddParamIntN(rawValue, Int32(bits), valData, isOutput)
    }

    /// Add a bool type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamBool(val: Bool, isOutput: Bool) -> Int32 {
        return TWEthereumAbiFunctionAddParamBool(rawValue, val, isOutput)
    }

    /// Add a string type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamString(val: String, isOutput: Bool) -> Int32 {
        let valString = TWStringCreateWithNSString(val)
        defer {
            TWStringDelete(valString)
        }
        return TWEthereumAbiFunctionAddParamString(rawValue, valString, isOutput)
    }

    /// Add an address type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamAddress(val: Data, isOutput: Bool) -> Int32 {
        let valData = TWDataCreateWithNSData(val)
        defer {
            TWDataDelete(valData)
        }
        return TWEthereumAbiFunctionAddParamAddress(rawValue, valData, isOutput)
    }

    /// Add a bytes type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamBytes(val: Data, isOutput: Bool) -> Int32 {
        let valData = TWDataCreateWithNSData(val)
        defer {
            TWDataDelete(valData)
        }
        return TWEthereumAbiFunctionAddParamBytes(rawValue, valData, isOutput)
    }

    /// Add a bytes[N] type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter size: fixed size of the bytes array parameter (val).
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamBytesFix(size: Int, val: Data, isOutput: Bool) -> Int32 {
        let valData = TWDataCreateWithNSData(val)
        defer {
            TWDataDelete(valData)
        }
        return TWEthereumAbiFunctionAddParamBytesFix(rawValue, size, valData, isOutput)
    }

    /// Add a type[] type parameter
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter val: for output parameters, value has to be specified
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the index of the parameter (0-based).
    @discardableResult
    public func addParamArray(isOutput: Bool) -> Int32 {
        return TWEthereumAbiFunctionAddParamArray(rawValue, isOutput)
    }

    /// Methods for accessing the value of an output or input parameter, of different types.
    /// Get a uint8 type parameter at the given index
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter idx: index for the parameter (0-based).
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the value of the parameter.
    public func getParamUInt8(idx: Int32, isOutput: Bool) -> UInt8 {
        return TWEthereumAbiFunctionGetParamUInt8(rawValue, Int32(idx), isOutput)
    }

    /// Get a uint64 type parameter at the given index
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter idx: index for the parameter (0-based).
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the value of the parameter.
    public func getParamUInt64(idx: Int32, isOutput: Bool) -> UInt64 {
        return TWEthereumAbiFunctionGetParamUInt64(rawValue, Int32(idx), isOutput)
    }

    /// Get a uint256 type parameter at the given index
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter idx: index for the parameter (0-based).
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the value of the parameter stored in a block of data.
    public func getParamUInt256(idx: Int32, isOutput: Bool) -> Data {
        return TWDataNSData(TWEthereumAbiFunctionGetParamUInt256(rawValue, Int32(idx), isOutput))
    }

    /// Get a bool type parameter at the given index
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter idx: index for the parameter (0-based).
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the value of the parameter.
    public func getParamBool(idx: Int32, isOutput: Bool) -> Bool {
        return TWEthereumAbiFunctionGetParamBool(rawValue, Int32(idx), isOutput)
    }

    /// Get a string type parameter at the given index
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter idx: index for the parameter (0-based).
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the value of the parameter.
    public func getParamString(idx: Int32, isOutput: Bool) -> String {
        return TWStringNSString(TWEthereumAbiFunctionGetParamString(rawValue, Int32(idx), isOutput))
    }

    /// Get an address type parameter at the given index
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter idx: index for the parameter (0-based).
    /// - Parameter isOutput: determines if the parameter is an input or output
    /// - Returns: the value of the parameter.
    public func getParamAddress(idx: Int32, isOutput: Bool) -> Data {
        return TWDataNSData(TWEthereumAbiFunctionGetParamAddress(rawValue, Int32(idx), isOutput))
    }

    /// Methods for adding a parameter of the given type to a top-level input parameter array.  Returns the index of the parameter (0-based).
    /// Note that nested ParamArrays are not possible through this API, could be done by using index paths like "1/0"
    /// Adding a uint8 type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamUInt8(arrayIdx: Int32, val: UInt8) -> Int32 {
        return TWEthereumAbiFunctionAddInArrayParamUInt8(rawValue, Int32(arrayIdx), val)
    }

    /// Adding a uint16 type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamUInt16(arrayIdx: Int32, val: UInt16) -> Int32 {
        return TWEthereumAbiFunctionAddInArrayParamUInt16(rawValue, Int32(arrayIdx), val)
    }

    /// Adding a uint32 type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamUInt32(arrayIdx: Int32, val: UInt32) -> Int32 {
        return TWEthereumAbiFunctionAddInArrayParamUInt32(rawValue, Int32(arrayIdx), val)
    }

    /// Adding a uint64 type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamUInt64(arrayIdx: Int32, val: UInt64) -> Int32 {
        return TWEthereumAbiFunctionAddInArrayParamUInt64(rawValue, Int32(arrayIdx), val)
    }

    /// Adding a uint256 type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter stored in a block of data
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamUInt256(arrayIdx: Int32, val: Data) -> Int32 {
        let valData = TWDataCreateWithNSData(val)
        defer {
            TWDataDelete(valData)
        }
        return TWEthereumAbiFunctionAddInArrayParamUInt256(rawValue, Int32(arrayIdx), valData)
    }

    /// Adding a uint[N] type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter bits: Number of bits of the integer parameter
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter stored in a block of data
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamUIntN(arrayIdx: Int32, bits: Int32, val: Data) -> Int32 {
        let valData = TWDataCreateWithNSData(val)
        defer {
            TWDataDelete(valData)
        }
        return TWEthereumAbiFunctionAddInArrayParamUIntN(rawValue, Int32(arrayIdx), Int32(bits), valData)
    }

    /// Adding a int8 type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamInt8(arrayIdx: Int32, val: Int8) -> Int32 {
        return TWEthereumAbiFunctionAddInArrayParamInt8(rawValue, Int32(arrayIdx), val)
    }

    /// Adding a int16 type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamInt16(arrayIdx: Int32, val: Int16) -> Int32 {
        return TWEthereumAbiFunctionAddInArrayParamInt16(rawValue, Int32(arrayIdx), val)
    }

    /// Adding a int32 type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamInt32(arrayIdx: Int32, val: Int32) -> Int32 {
        return TWEthereumAbiFunctionAddInArrayParamInt32(rawValue, Int32(arrayIdx), val)
    }

    /// Adding a int64 type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamInt64(arrayIdx: Int32, val: Int64) -> Int32 {
        return TWEthereumAbiFunctionAddInArrayParamInt64(rawValue, Int32(arrayIdx), val)
    }

    /// Adding a int256 type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter stored in a block of data
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamInt256(arrayIdx: Int32, val: Data) -> Int32 {
        let valData = TWDataCreateWithNSData(val)
        defer {
            TWDataDelete(valData)
        }
        return TWEthereumAbiFunctionAddInArrayParamInt256(rawValue, Int32(arrayIdx), valData)
    }

    /// Adding a int[N] type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter bits: Number of bits of the integer parameter
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter stored in a block of data
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamIntN(arrayIdx: Int32, bits: Int32, val: Data) -> Int32 {
        let valData = TWDataCreateWithNSData(val)
        defer {
            TWDataDelete(valData)
        }
        return TWEthereumAbiFunctionAddInArrayParamIntN(rawValue, Int32(arrayIdx), Int32(bits), valData)
    }

    /// Adding a bool type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamBool(arrayIdx: Int32, val: Bool) -> Int32 {
        return TWEthereumAbiFunctionAddInArrayParamBool(rawValue, Int32(arrayIdx), val)
    }

    /// Adding a string type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamString(arrayIdx: Int32, val: String) -> Int32 {
        let valString = TWStringCreateWithNSString(val)
        defer {
            TWStringDelete(valString)
        }
        return TWEthereumAbiFunctionAddInArrayParamString(rawValue, Int32(arrayIdx), valString)
    }

    /// Adding an address type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamAddress(arrayIdx: Int32, val: Data) -> Int32 {
        let valData = TWDataCreateWithNSData(val)
        defer {
            TWDataDelete(valData)
        }
        return TWEthereumAbiFunctionAddInArrayParamAddress(rawValue, Int32(arrayIdx), valData)
    }

    /// Adding a bytes type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter val: the value of the parameter
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamBytes(arrayIdx: Int32, val: Data) -> Int32 {
        let valData = TWDataCreateWithNSData(val)
        defer {
            TWDataDelete(valData)
        }
        return TWEthereumAbiFunctionAddInArrayParamBytes(rawValue, Int32(arrayIdx), valData)
    }

    /// Adding a int64 type parameter of to the top-level input parameter array
    ///
    /// - Parameter fn: A Non-null eth abi function
    /// - Parameter arrayIdx: array index for the abi function (0-based).
    /// - Parameter size: fixed size of the bytes array parameter (val).
    /// - Parameter val: the value of the parameter
    /// - Returns: the index of the added parameter (0-based).
    @discardableResult
    public func addInArrayParamBytesFix(arrayIdx: Int32, size: Int, val: Data) -> Int32 {
        let valData = TWDataCreateWithNSData(val)
        defer {
            TWDataDelete(valData)
        }
        return TWEthereumAbiFunctionAddInArrayParamBytesFix(rawValue, Int32(arrayIdx), size, valData)
    }

}
