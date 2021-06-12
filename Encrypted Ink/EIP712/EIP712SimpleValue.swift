//
// This source file is part of the 0x.swift open source project
// Copyright 2019 The 0x.swift Authors
// Licensed under Apache License v2.0
//
// EIP712SimpleValue.swift
//
// Created by Igor Shmakov on 15/04/2019
//

import Foundation
import Web3Swift

public struct EIP712SimpleValue: EIP712Value {
    
    public let parameter: EIP712Parameter
    public let value: Any
    
    public func makeABIEncodedParameter() throws -> ABIEncodedParameter {
        
        let encoder = EIP712ValueEncoder(type: parameter.type, value: value)
        return try encoder.makeABIEncodedParameter()
    }
}
