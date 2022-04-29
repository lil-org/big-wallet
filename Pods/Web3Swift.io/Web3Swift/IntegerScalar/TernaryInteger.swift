//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// TernaryInteger.swift
//
// Created by Timofey Solonin on 22/05/2018
//

import Foundation

/** Integer value that is based on a boolean evaluation */
public final class TernaryInteger: IntegerScalar {

    private let ternary: Ternary<Int>

    /**
    Ctor

    - parameters:
        - if: boolean condition for definition of integer
        - then: integer representation associated with true
        - else: integer representation associated with false
    */
    public init(
        if: BooleanScalar,
        then: IntegerScalar,
        else: IntegerScalar
    ) {
        self.ternary = Ternary<Int>(
            if: `if`,
            then: { try then.value() },
            else: { try `else`.value() }
        )
    }

    /**
    - returns:
    If `if` is true, then `then`, else `else`
    */
    public func value() throws -> Int {
        return try ternary.value()
    }

}