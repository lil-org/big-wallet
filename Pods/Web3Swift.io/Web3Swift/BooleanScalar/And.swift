//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// And.swift
//
// Created by Timofey Solonin on 19/05/2018
//

import Foundation

/** `And` logic gate */
public final class And: BooleanScalar {

    private let conditions: CollectionScalar<BooleanScalar>

    /**
    Ctor

    - parameters:
        - conditions: 2 or more conditions to verify
    */
    public init(conditions: CollectionScalar<BooleanScalar>) {
        self.conditions = SizeConstrainedCollection(
            origin: conditions,
            minimum: 2
        )
    }

    /**
    Ctor

    - parameters:
        - conditions: 2 or more conditions to verify
    */
    public convenience init(conditions: [BooleanScalar]) {
        self.init(
            conditions: SimpleCollection(
                collection: conditions
            )
        )
    }

    /**
    Ctor

    - parameters:
        - conditions: 2 or more conditions to verify
    */
    public convenience init(conditions: [Bool]) {
        self.init(
            conditions: MappedCollection(
                origin: SimpleCollection(
                    collection: conditions
                ),
                mapping: {
                    SimpleBoolean(bool: $0)
                }
            )
        )
    }

    /**
    Ctor

    - parameters:
        - lhs: first condition
        - rhs: second condition
    */
    public convenience init(
        lhs: BooleanScalar,
        rhs: BooleanScalar
    ) {
        self.init(
            conditions: [
                lhs,
                rhs
            ]
        )
    }

    /**
    Ctor

    - parameters:
        - lhs: first condition
        - rhs: second condition
    */
    public convenience init(
        lhs: Bool,
        rhs: Bool
    ) {
        self.init(
            conditions: [
                SimpleBoolean(
                    bool: lhs
                ),
                SimpleBoolean(
                    bool: rhs
                )
            ]
        )
    }

    /**
    - returns:
    True iff all conditions evaluate to true.

    - Important:
    Statements are verified only to the first `false`. None of the conditions after `false` will be verified.
    */
    public func value() throws -> Bool {
        var result = true
        for condition in try conditions.value() {
            if try condition.value() == false {
                result = false
                break
            }
        }
        return result
    }

}