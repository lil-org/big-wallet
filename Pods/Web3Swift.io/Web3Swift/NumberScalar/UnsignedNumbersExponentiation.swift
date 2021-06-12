//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// UnsignedNumbersExponentiation.swift
//
// Created by Timofey Solonin on 23/05/2018
//

import BigInt
import Foundation

/** An exponentiation of unsigned big endian numbers of arbitrary length */
public final class UnsignedNumbersExponentiation: BytesScalar {

    private let base: BytesScalar
    private let exponent: IntegerScalar

    /**
    Ctor

    - parameters:
        - base: number to raise to power
        - exponent: power to raise to
    */
    public init(
        base: BytesScalar,
        exponent: IntegerScalar
    ) {
        self.base = base
        self.exponent = NaturalInteger(
            origin: exponent
        )
    }

    /**
    - returns:
    Number raised to the specified power
    */
    public func value() throws -> Data {
        return try BigUInt(
            base.value()
        ).power(
            exponent.value()
        ).serialize()
    }

}