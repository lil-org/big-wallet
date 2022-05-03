//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ABITupleEncoding.swift
//
// Created by Тимофей Солонин on 14.02.2019
//

import Foundation

/** Raw tuple encoding */
internal final class ABITupleEncoding: CollectionScalar<BytesScalar> {
    
    private let parameters: [ABIEncodedParameter]

    /**
    Ctor

    - parameters:
        - parameters: a collection of parameters to be encoded as a tuple
    */
    internal init(parameters: [ABIEncodedParameter]) {
        self.parameters = parameters
    }
    
    /**
    - returns:
    A sum of heads and tails of the parameters
    */
    internal override func value() throws -> [BytesScalar] {
        var additionalOffset: Int = headsCount()
        var heads: [BytesScalar] = []
        var tails: [BytesScalar] = []
        try parameters.forEach{ parameter in
            heads += try parameter.heads(
                offset: additionalOffset
            )
            let parameterTails = try parameter.tails(
                offset: additionalOffset
            )
            tails += parameterTails
            additionalOffset += parameterTails.count
        }
        return heads + tails
    }
    
    //TODO: headsCount should probably be injected
    /**
    - returns:
    A sum of headsCount of the parameters
    */
    internal func headsCount() -> Int {
        return parameters.reduce(into: 0) { count, parameter in count += parameter.headsCount() }
    }
    
}
