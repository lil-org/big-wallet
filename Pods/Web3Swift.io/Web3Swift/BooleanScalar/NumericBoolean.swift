//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// NumericBoolean.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

internal final class NotANumericBooleanError: DescribedError {

    private let number: Int
    public init(number: Int) {
        self.number = number
    }

    internal var description: String {
        return "Numeric value \(number) does not represent a boolean. 0 or 1 was expected."
    }

}

/** Boolean from a numeric value of 0 or 1 */
public final class NumericBoolean: BooleanScalar {

    private let bool: BytesScalar

    /**
    Ctor

    - parameters:
        - bool: boolean value represented as a number
    */
    public init(bool: BytesScalar) {
        self.bool = FixedLengthBytes(
            origin: bool,
            length: 1
        )
    }

    /**
    - returns:
    true if numeric representation is 1, false if numeric representation is 0

    - throws:
    `DescribedError` if something went wrong. I.e. number was not 1 or 0.
    */
    public func value() throws -> Bool {
        let value = try bool.value().single()
        if value == 0 {
            return false
        } else if value == 1 {
            return true
        } else {
            throw NotANumericBooleanError(
                number: Int(
                    value
                )
            )
        }
    }

}
