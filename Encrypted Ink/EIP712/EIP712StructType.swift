//
// This source file is part of the 0x.swift open source project
// Copyright 2019 The 0x.swift Authors
// Licensed under Apache License v2.0
//
// EIP712StructType.swift
//
// Created by Igor Shmakov on 15/04/2019
//

import Foundation

public struct EIP712StructType {
    
    public let types: [EIP712Type]
    
    public var primaryType: EIP712Type? {
        return types.first
    }
    
    public init(primary: EIP712Type, referenced: [EIP712Type] = []) {
        types = [primary] + referenced.sorted { $0.name < $1.name }
    }
    
    public func encode() -> String {
        return types.reduce("") { $0 + $1.encode()}
    }
    
    public func hashType() throws -> Data {
        return encode().data(using: .utf8)!.sha3(.keccak256)
    }
}
