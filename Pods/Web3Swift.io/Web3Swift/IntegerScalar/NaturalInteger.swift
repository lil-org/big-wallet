//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// NaturalInteger.swift
//
// Created by Timofey Solonin on 22/05/2018
//

import Foundation

/** Integer from 0 to Int.max */
public final class NaturalInteger: IntegerScalar {

    private let origin: IntegerScalar

    /**
    Ctor

    - parameters:
        - origin: integer to constraint to a natural set
    */
    public init(origin: IntegerScalar) {
        self.origin = RangeConstrainedInteger(
            origin: origin,
            minimum: 0,
            maximum: Int.max
        )
    }

    /**
    - returns:
    Integer that is between 0 and Int.max

    - throws:
    `DescribedError` if something went wrong. I.e. if value was not in a natural set.
    */
    public func value() throws -> Int {
        return try origin.value()
    }

}