//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// QuantityParameter.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

public final class QuantityParameter: EthParameter {

    private let number: BytesScalar

    /**
    Ctor

    - parameters:
        - number: number to be converted to parameter
    */
    public init(number: BytesScalar) {
        self.number = number
    }

    /**
    - returns:
    `String` representation of the number as specified by ethereum JSON RPC (dropping any leading zeroes in string representation)

    - throws:
    `DescribedError` is something went wrong
    */
    public func value() throws -> Any {
        return try HexPrefixedString(
            origin: CompactHexString(
                bytes: number
            )
        ).value()
    }

}
