//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ABITuple.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** A collection of non dynamic elements of fixed length. Parameters of the ABI function are a dynamically typed tuple. Fixed length ABI arrays are a statically typed flatmapped tuple. */
public final class ABITuple: ABIEncodedParameter {

    private let encoding: ABITupleEncoding
    private let parameters: [ABIEncodedParameter]

    /**
    Ctor

    - parameters:
        - parameters: a collection of parameters to be encoded as a tuple
    */
    public init(parameters: [ABIEncodedParameter]) {
        self.parameters = parameters
        encoding = ABITupleEncoding(parameters: parameters)
    }
    
    /**
    - parameters:
        - offset: number of elements preceding the tuple tails

    - returns:
    A collection of heads followed by tails of the tuple parameters
    */
    public func heads(offset: Int) throws -> [BytesScalar] {
        let heads: [BytesScalar]
        if isDynamic() {
            heads = [
                LeftZeroesPaddedBytes(
                    origin: SimpleBytes{
                        try EthNumber(
                            value: offset * 32
                        ).value()
                    },
                    length: 32
                )
            ]
        } else {
            heads = try encoding.value()
        }
        return heads
    }

    /**
    - parameters:
        - offset: invariant for tails

    - returns:
    Empty collection
    */
    public func tails(offset: Int) throws -> [BytesScalar] {
        let tails: [BytesScalar]
        if isDynamic() {
            tails = try encoding.value()
        } else {
            tails = []
        }
        return tails
    }

    /**
    - returns:
    true if contains at least one dynamic parameter, false otherwise
    */
    public func isDynamic() -> Bool {
        return parameters.contains(where: { $0.isDynamic() })
    }

    /**
    - returns:
    If tuple is dynamic it has a single head which is its offset. If tuple is static its heads count is a sum of its parameters heads count
    */
    public func headsCount() -> Int {
        let count: Int
        if isDynamic() {
            count = 1
        } else {
            count = encoding.headsCount()
        }
        return count
    }

}

