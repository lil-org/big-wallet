//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// NumberHex.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Hex of a Number */
public class NumberHex: BytesScalar {

    private let number: BytesScalar

    /**
    Ctor

    - parameters:
        - number: number to take the hex from
    */
    public init(number: BytesScalar) {
        self.number = number
    }

    /**
    - returns:
    Hex of the number as `Data`
    */
    public func value() throws -> Data {
        return try number.value()
    }

}
