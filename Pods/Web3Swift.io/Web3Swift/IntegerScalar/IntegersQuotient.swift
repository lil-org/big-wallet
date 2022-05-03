//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// IntegersQuotient.swift
//
// Created by Timofey Solonin on 17/05/2018
//

import Foundation

/** Quotient of two integers */
public final class IntegersQuotient: IntegerScalar {

    private let dividend: IntegerScalar
    private let divisor: IntegerScalar

    /**
    Ctor

    - parameters:
        - dividend: number to divide
        - divisor: number to divide by
    */
    public init(dividend: IntegerScalar, divisor: IntegerScalar) {
        self.dividend = dividend
        self.divisor = divisor
    }

    /**
    - returns:
    Quotient of integers dividend and divisor as dividend / divisor dropping decimal part.

    - throws:
    `DescribedError` if something went wrong. I.e. if divided by 0 or Int.min by -1.
    */
    public func value() throws -> Int {
        return try dividend.value().divideSafely(by: divisor.value())
    }

}