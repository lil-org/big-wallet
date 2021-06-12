//
// This source file is part of the 0x.swift open source project
// Copyright 2019 The 0x.swift Authors
// Licensed under Apache License v2.0
//
// EIP712ValueEncoder.swift
//
// Created by Igor Shmakov on 15/04/2019
//

import Foundation
import BigInt
import Web3Swift

public final class EIP712ValueEncoder {

    private let type: EIP712ParameterType
    private let value: Any
    
    public init(type: EIP712ParameterType, value: Any) {
        
        self.type = type
        self.value = value
    }
    
    public func makeABIEncodedParameter() throws -> ABIEncodedParameter {
        
        switch type {
        case .bool:
            return try encodeBool()
        case .address:
            return try encodeAddress()
        case .string:
            return try encodeString()
        case .fixedBytes:
            return try encodeFixedBytes()
        case .uint, .int:
            return try encodeInt()
        case .bytes:
            return try encodeBytes()
        case .object:
            return try encodeObject()
        }
    }
}

extension EIP712ValueEncoder {
    
    private func encodeBool() throws -> ABIEncodedParameter {
        
        guard let bool = value as? Bool else {
            throw EIP712Error.invalidTypedDataValue
        }
        return ABIBoolean(origin: bool)
    }
    
    private func encodeAddress() throws -> ABIEncodedParameter {
        
        guard let value = value as? String else {
            throw EIP712Error.invalidTypedDataValue
        }
        return ABIAddress(address: EthAddress(hex: value))
    }
    
    private func encodeString() throws -> ABIEncodedParameter {
        
        guard let value = value as? String, let data = value.data(using: .utf8) else {
            throw EIP712Error.invalidTypedDataValue
        }
        return ABIFixedBytes(origin: SimpleBytes(bytes: data.sha3(.keccak256)))
    }
    
    private func encodeFixedBytes() throws -> ABIEncodedParameter {
        
        let data: Data
        if let value = value as? String {
            data = Data(hex: value)
        } else if let value = value as? Data {
            data = value
        } else {
            throw EIP712Error.invalidTypedDataValue
        }
        return ABIFixedBytes(origin: SimpleBytes(bytes: data))
    }
    
    private func encodeInt() throws -> ABIEncodedParameter {
        
        let number: Int
        if let value = value as? Int {
            number = value
        } else if let str = value as? String {
            return ABIUnsignedNumber(origin: EthNumber(hex: str))
        } else {
            throw EIP712Error.invalidTypedDataValue
        }
        return ABIUnsignedNumber(origin: EthNumber(value: number))
    }
    
    private func encodeBytes() throws -> ABIEncodedParameter {
        
        let data: Data
        if let value = value as? String {
            data = Data(hex: value)
        } else if let value = value as? Data {
            data = value
        } else {
            throw EIP712Error.invalidTypedDataValue
        }
        return ABIFixedBytes(origin: SimpleBytes(bytes: data.sha3(.keccak256)))
    }
    
    private func encodeObject() throws -> ABIEncodedParameter {
        
        guard let value = value as? EIP712Representable else {
            throw EIP712Error.invalidTypedDataValue
        }
        return ABIFixedBytes(origin: SimpleBytes(bytes: try value.hash()))
    }
}
