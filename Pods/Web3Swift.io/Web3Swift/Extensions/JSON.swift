//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// JSON.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

internal class InvalidTypeError<T>: DescribedError {

    private let json: JSON
    private let typeName: String
    public init(json: JSON, expectedType: T.Type) {
        self.json = json
        self.typeName = String(describing: expectedType)
    }

    internal var description: String {
        return "Expected type was \(typeName) but it was actually \(String(describing: json.type))"
    }

}

extension JSON {

    public init(dictionary: [String: Any]) {
        self.init(dictionary)
    }

    /**
    - returns:
    `Int` representation from `JSON` value
    
    - throws:
    `DescribedError` if the type was not an `Int`
    */
    internal func int() throws -> Int {
        if let int = self.int {
            return int
        } else {
            throw InvalidTypeError(json: self, expectedType: Int.self)
        }
    }

    /**
    - returns:
    `String` representation from `JSON` value
    
    - throws:
    `DescribedError` if the type was not an `String`
    */
    internal func string() throws -> String {
        if let string = self.string {
            return string
        } else {
            throw InvalidTypeError(json: self, expectedType: String.self)
        }
    }
    
    /**
     - returns:
     `Bool` representation from `JSON` value
     
     - throws:
     `DescribedError` if the type was not an `Bool`
     */
    internal func bool() throws -> Bool {
        if let boolean = self.bool {
            return boolean
        } else {
            throw InvalidTypeError(json: self, expectedType: Bool.self)
        }
    }
    
    /**
     - returns:
     `Array` representation from `JSON` value
     
     - throws:
     `DescribedError` if the type was not an `Array`
     */
    internal func array() throws -> [SwiftyJSON.JSON] {
        if let array = self.array {
            return array
        } else {
            throw InvalidTypeError(json: self, expectedType: [SwiftyJSON.JSON].self)
        }
    }
}
