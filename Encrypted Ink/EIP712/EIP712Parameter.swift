//
// This source file is part of the 0x.swift open source project
// Copyright 2019 The 0x.swift Authors
// Licensed under Apache License v2.0
//
// EIP712Parameter.swift
//
// Created by Igor Shmakov on 15/04/2019
//

import Foundation

public enum EIP712ParameterType {
    
    case bool
    case address
    case string
    case bytes
    case fixedBytes(len: Int)
    case uint(len: Int)
    case int(len: Int)
    case object(name: String)
    
    private static func parseBytesSize(type: String, prefix: String) throws -> Int {
        
        guard type.starts(with: prefix) else {
            throw EIP712Error.invalidType(name: type)
        }
        guard let size = Int(type.dropFirst(prefix.count)) else {
            throw EIP712Error.invalidType(name: type)
        }
        if size < 1 || size > 32 {
            throw EIP712Error.invalidType(name: type)
        }
        return size
    }
    
    private static func parseIntSize(type: String, prefix: String) throws -> Int {
        
        guard type.starts(with: prefix) else {
            throw EIP712Error.invalidType(name: type)
        }
        guard let size = Int(type.dropFirst(prefix.count)) else {
            if type == prefix {
                return 256
            }
            throw EIP712Error.invalidType(name: type)
        }
        if size < 8 || size > 256 || size % 8 != 0 {
            throw EIP712Error.invalidType(name: type)
        }
        return size
    }
    
    public static func parse(type: String) throws -> EIP712ParameterType {
        
        if type == "bool" {
            return .bool
        }
        
        if type == "address" {
            return .address
        }
        
        if type == "string" {
            return .string
        }
        
        if type == "bytes" {
            return .bytes
        }
        
        if type.hasPrefix("uint") {
            return try .uint(len: parseIntSize(type: type, prefix: "uint"))
        }
        
        if type.hasPrefix("int") {
            return try .int(len: parseIntSize(type: type, prefix: "int"))
        }
        
        if type.hasPrefix("bytes") {
            return try .fixedBytes(len: parseBytesSize(type: type, prefix: "bytes"))
        }
        
        return object(name: type)
    }
    
    public func raw() -> String {
        
        switch self {
        case .bool: return "bool"
        case .address: return "address"
        case .string: return "string"
        case let .fixedBytes(len): return "bytes\(len)"
        case let .uint(len): return "uint\(len)"
        case let .int(len): return "int\(len)"
        case .bytes: return "bytes"
        case let .object(name): return name
        }
    }
}


public struct EIP712Parameter {
    
    public let name: String
    public let type: EIP712ParameterType
    
    public func encode() -> String {
        return "\(type.raw()) \(name)"
    }
}
