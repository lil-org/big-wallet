//
// This source file is part of the 0x.swift open source project
// Copyright 2019 The 0x.swift Authors
// Licensed under Apache License v2.0
//
// EIP712TypedData.swift
//
// Created by Igor Shmakov on 12/04/2019
//

import Foundation
import SwiftyJSON
import Web3Swift
import BigInt

public class EIP712TypedData {
    
    public private(set) var type: EIP712StructType!
    public private(set) var domain: EIP712Domain!
    public private(set) var encodedData: Data!
    
    private let domainType = "EIP712Domain"
    
    public convenience init(jsonData: Data) throws {
        try self.init(json: try JSON(data: jsonData))
    }
    
    public convenience init(jsonString: String) throws {
        try self.init(json: JSON(parseJSON: jsonString))
    }
    
    public convenience init(jsonObject: Any) throws {
        try self.init(json: JSON(jsonObject))
    }
    
    public init(json: JSON) throws {

        let jsonDomain = json["domain"]
        let jsonMessage = json["message"]
        
        guard
            let jsonTypes = json["types"].dictionary,
            let primaryTypeName = json["primaryType"].string
        else {
            throw EIP712Error.invalidTypedData
        }
        
        let types = try parseTypes(jsonTypes: jsonTypes)

        guard let primaryType = types[primaryTypeName] else {
            throw EIP712Error.invalidTypedDataPrimaryType
        }
        
        guard let domainType = types[domainType] else {
            throw EIP712Error.invalidTypedDataDomain
        }
        
        let dependencies = try findTypeDependencies(primaryType: primaryType, types: types).filter { $0.name != primaryType.name }
        let type = EIP712StructType(primary: primaryType, referenced: dependencies)
        let domain = try parseDomain(jsonDomain: jsonDomain, type: domainType)
        let data = try encodeData(data: jsonMessage, primaryType: primaryType, types: types)
        
        self.type = type
        self.encodedData = data
        self.domain = domain
    }

    private func parseDomain(jsonDomain: JSON, type: EIP712Type) throws -> EIP712Domain {
        
        return EIP712Domain(name: jsonDomain["name"].string,
                            version: jsonDomain["version"].string,
                            chainID: jsonDomain["chainId"].int,
                            verifyingContract: jsonDomain["verifyingContract"].string,
                            salt: jsonDomain["salt"].string?.data(using: .utf8))
    }
    
    private func parseTypes(jsonTypes: [String: JSON]) throws -> [String: EIP712Type] {
    
        var types = [String: EIP712Type]()
        
        for (name, jsonParameters) in jsonTypes {
            var parameters = [EIP712Parameter]()
            for (_, jsonParameter) in jsonParameters {
                guard
                    let name = jsonParameter["name"].string,
                    let type = jsonParameter["type"].string
                else {
                    throw EIP712Error.invalidTypedDataType
                }
                parameters.append(EIP712Parameter(name: name, type: try EIP712ParameterType.parse(type: type)))
            }
            let type = EIP712Type(name: name, parameters: parameters)
            types[name] = type
        }
        
        return types
    }
    
    private func findTypeDependencies(primaryType: EIP712Type, types: [String: EIP712Type], results: [EIP712Type] = []) throws -> [EIP712Type] {
        
        var results = results
        if (results.contains(where: { $0.name == primaryType.name }) || types[primaryType.name] == nil) {
            return results
        }

        results.append(primaryType)
        
        for parameter in primaryType.parameters {
            if let type = types[parameter.type.raw()] {
                let dependencies = try findTypeDependencies(primaryType: type, types: types, results: results)
                results += dependencies.filter { dep in !results.contains(where: { res in res.name == dep.name }) }
            }
        }
        return results
    }
    
    private func encodeType(primaryType: EIP712Type, types: [String: EIP712Type]) throws -> EIP712StructType {
        
        let dependencies = try findTypeDependencies(primaryType: primaryType, types: types).filter { $0.name != primaryType.name }
        return EIP712StructType(primary: primaryType, referenced: dependencies)
    }
    
    private func hashType(primaryType: EIP712Type, types: [String: EIP712Type]) throws -> Data {
        
        let type = try encodeType(primaryType: primaryType, types: types)
        return try type.hashType()
    }
    
    private func encodeData(data: JSON, primaryType: EIP712Type, types: [String: EIP712Type]) throws -> Data {
        
        var encodedTypes: [EIP712ParameterType] = [.fixedBytes(len: 32)]
        var encodedValues: [Any] = [try self.hashType(primaryType: primaryType, types: types)]
        
        for parameter in primaryType.parameters {
            let value = data[parameter.name]
            if let type = types[parameter.type.raw()] {
                encodedTypes.append(.fixedBytes(len: 32))
                let data = try encodeData(data: value, primaryType: type, types: types)
                encodedValues.append(data.sha3(.keccak256))
            } else {
                encodedTypes.append(parameter.type)
                encodedValues.append(value.object)
            }
        }
        
        let parameters = try zip(encodedTypes, encodedValues).map {
            try EIP712ValueEncoder(type: $0.0, value: $0.1).makeABIEncodedParameter()
        }
        
        return try EncodedABITuple(parameters: parameters).value()
    }
}

extension EIP712TypedData: EIP712Hashable {
    
    public func hash() throws -> Data {
        
        return encodedData.sha3(.keccak256)
    }
}
