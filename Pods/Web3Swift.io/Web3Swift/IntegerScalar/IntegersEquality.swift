//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// IntegerEquality.swift
//
// Created by Timofey Solonin on 19/05/2018
//

import Foundation

/** Boolean equality of two integers */
public final class IntegersEquality: BooleanScalar {

    private let lhs: IntegerScalar
    private let rhs: IntegerScalar

    /**
    Ctor

    - parameters:
        - lhs: first integer
        - rhs: second integer
    */
    public init(lhs: IntegerScalar, rhs: IntegerScalar) {
        self.lhs = lhs
        self.rhs = rhs
    }

    /**
    - returns:
    True is integers are equal, false if they are not
    */
    public func value() throws -> Bool {
        return try lhs.value() == rhs.value()
    }

}