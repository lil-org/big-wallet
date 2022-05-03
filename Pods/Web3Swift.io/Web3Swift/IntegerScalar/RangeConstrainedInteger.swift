//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// RangeConstrainedInteger.swift
//
// Created by Timofey Solonin on 19/05/2018
//

import Foundation

internal final class IntegerOutOfRange: DescribedError {

    private let value: Int
    private let minimum: Int
    private let maximum: Int

    internal init(
        value: Int,
        minimum: Int,
        maximum: Int
    ) {
        self.value = value
        self.minimum = minimum
        self.maximum = maximum
    }

    internal var description: String {
        return "Value of \(value) if out of range [\(minimum), \(maximum)]"
    }

}

internal final class IncorrectRange: DescribedError {

    private let minimum: Int
    private let maximum: Int

    internal init(
        minimum: Int,
        maximum: Int
    ) {
        self.minimum = minimum
        self.maximum = maximum
    }

    internal var description: String {
        return "Range with a minimum of \(minimum) and a maximum of \(maximum) is not a valid range"
    }

}

/** Integer that is constrained to a range of values */
public final class RangeConstrainedInteger: IntegerScalar {

    private let origin: IntegerScalar
    private let minimum: IntegerScalar
    private let maximum: IntegerScalar

    /**
    Ctor

    - parameters:
        - origin: integer to constraint
        - minimum: inclusive minimum allowed value that is >= maximum
        - maximum: inclusive maximum allowed value that is <= minimum
    */
    public init(
        origin: IntegerScalar,
        minimum: IntegerScalar,
        maximum: IntegerScalar
    ) {
        self.origin = origin
        self.minimum = minimum
        self.maximum = maximum
    }

    /**
    Ctor

    - parameters:
        - origin: integer to constraint
        - minimum: inclusive minimum allowed value that is >= maximum
        - maximum: inclusive maximum allowed value that is <= minimum
    */
    public convenience init(
        origin: IntegerScalar,
        minimum: Int,
        maximum: Int
    ) {
        self.init(
            origin: origin,
            minimum: SimpleInteger(
                integer: minimum
            ),
            maximum: SimpleInteger(
                integer: maximum
            )
        )
    }

    /**
    - returns:
    Value that is within the bounds [minimum; maximum]

    - throws:
    `DescribedError` if something went wrong. I.e. if bounds were set incorrect or if value was out of bounds.
    */
    public func value() throws -> Int {
        let minimum = try self.minimum.value()
        let maximum = try self.maximum.value()
        guard minimum <= maximum else {
            throw IncorrectRange(
                minimum: minimum,
                maximum: maximum
            )
        }
        let origin = try self.origin.value()
        guard (minimum...maximum).contains(origin) else {
            throw IntegerOutOfRange(
                value: origin,
                minimum: minimum,
                maximum: maximum
            )
        }
        return origin
    }

}