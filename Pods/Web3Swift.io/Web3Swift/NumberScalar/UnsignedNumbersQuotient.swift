//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// UnsignedNumbersQuotient.swift
//
// Created by Timofey Solonin on 23/05/2018
//

import BigInt
import Foundation

/** A quotient of unsigned big endian numbers of arbitrary length */
public final class UnsignedNumbersQuotient: BytesScalar {

    private let dividend: BytesScalar
    private let divisor: BytesScalar

    /**
    Ctor

    - parameters:
        - dividend: number to divide
        - divisor: number to divide by
    */
    public init(
        dividend: BytesScalar,
        divisor: BytesScalar
    ) {
        self.dividend = dividend
        self.divisor = divisor
    }

    /**
    - returns:
    Quotient of integers dividend and divisor as dividend / divisor dropping decimal part.
    */
    public func value() throws -> Data {
        let divisor = try BigUInt(
            self.divisor.value()
        )
        guard divisor != 0 else {
            throw DivisionByZero()
        }
        return try (
            BigUInt(
                dividend.value()
            ) / divisor
        ).serialize()
    }

}