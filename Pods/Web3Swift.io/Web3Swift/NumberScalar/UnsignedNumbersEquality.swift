//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// UnsignedNumbersEquality.swift
//
// Created by Timofey Solonin on 23/05/2018
//

import BigInt
import Foundation

/** An equality of unsigned big endian numbers of arbitrary length */
public final class UnsignedNumbersEquality: BooleanScalar {

    private let lhs: BytesScalar
    private let rhs: BytesScalar

    /**
    Ctor

    - parameters:
        - lhs: first number
        - rhs: second number
    */
    public init(lhs: BytesScalar, rhs: BytesScalar) {
        self.lhs = lhs
        self.rhs = rhs
    }

    /**
    - returns:
    True if numbers are equal, else false
    */
    public func value() throws -> Bool {
        return try BigUInt(
            lhs.value()
        ) == BigUInt(
            rhs.value()
        )
    }

}
