//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// IntegersDifference.swift
//
// Created by Timofey Solonin on 17/05/2018
//

import Foundation

/** Difference between integers */
public final class IntegersDifference: IntegerScalar {

    private let minuend: IntegerScalar
    private let subtrahend: IntegerScalar

    /**
    Ctor

    - parameters:
        - minuend: integer to subtract from
        - subtrahend: integer to subtract
    */
    public init(minuend: IntegerScalar, subtrahend: IntegerScalar) {
        self.minuend = minuend
        self.subtrahend = subtrahend
    }

    /**
    - returns:
    Difference between minuend and subtrahend as minuend - subtrahend

    - throws:
    `DescribedError` if something went wrong. I.e. if difference results in an overflow
    */
    public func value() throws -> Int {
        return try subtrahend.value().subtractSafely(from: minuend.value())
    }

}