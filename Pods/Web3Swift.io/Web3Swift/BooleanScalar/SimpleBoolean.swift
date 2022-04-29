//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// SimpleBoolean.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Anonymous boolean scalar wrapper */
public final class SimpleBoolean: BooleanScalar {

    private let bool: () throws -> (Bool)

    /**
    Ctor

    - parameters:
        - bool: a closure that represents of a bool
    */
    public init(bool: @escaping () throws -> (Bool)) {
        self.bool = bool
    }

    /**
    Ctor

    - parameters:
        - bool: just a boolean value
    */
    public convenience init(bool: Bool) {
        self.init(bool: { bool })
    }

    /**
    - returns:
    `Bool` representation of a scalar

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Bool {
        return try bool()
    }

}
