//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ABIDynamicCollection.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** A collection of ABI parameters encoded as an ABI parameter */
public final class ABIDynamicCollection: ABIEncodedParameter {

    private let parameters: [ABIEncodedParameter]
    private let encoding: ABITupleEncoding

    /**
    Ctor

    - parameters:
        - parameters: ABI parameters to be encoded as a dynamic collection
    */
    public init(parameters: [ABIEncodedParameter]) {
        self.parameters = parameters
        encoding = ABITupleEncoding(parameters: parameters)
    }

    /**
    - parameters:
        - offset: number of elements preceding the dynamic collection tails

    - returns:
    A collection with a single element representing a distance from the beginning of the encoding to the tails of the dynamic collection
    */
    public func heads(offset: Int) throws -> [BytesScalar] {
        return [
            LeftZeroesPaddedBytes(
                origin: SimpleBytes{
                    try EthNumber(
                        value: offset * 32
                    ).value()
                },
                length: 32
            )
        ]
    }

    /**
    - parameters:
        - offset: number of elements preceding the dynamic collection tails

    - returns:
    A collection of the parameters encodings prefixed by the parameters count.
    */
    public func tails(offset: Int) throws -> [BytesScalar] {
        return try [
            LeftZeroesPaddedBytes(
                origin: SimpleBytes{ [parameters] in
                    try EthNumber(
                        value: parameters.count
                    ).value()
                },
                length: 32
            )
        ] + encoding.value()
    }

    /**
    - returns:
    true
    */
    public func isDynamic() -> Bool {
        return true
    }

    /**
    - returns:
    1
    */
    public func headsCount() -> Int {
        return 1
    }

}
