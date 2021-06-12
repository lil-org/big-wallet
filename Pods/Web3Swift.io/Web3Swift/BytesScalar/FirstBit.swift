//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// FirstBit.swift
//
// Created by Timofey Solonin on 22/05/2018
//

import Foundation

/** First (most significant) bit of a value */
public final class FirstBit: IntegerScalar {

    private let int: IntegerScalar

    /**
    Ctor

    - parameters:
        - value: value to take the bit from
    */
    public init(value: IntegerScalar) {
        self.int = value
    }

    /**
    - returns:
    0 if first bit is 0, 1 if first is 1
    */
    public func value() throws -> Int {
        let value = try int.value()
        return Int(
            UInt(bitPattern: value) >> (value.bitWidth - 1)
        )
    }

}