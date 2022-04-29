//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// SimpleInteger.swift
//
// Created by Timofey Solonin on 15/05/2018
//

import Foundation

/** Anonymous integer implementation */
public final class SimpleInteger: IntegerScalar {

    private let integer: () throws -> (Int)

    /**
    Ctor

    - parameters:
        - integer: closure representation of an integer
    */
    public init(integer: @escaping () throws -> (Int)) {
        self.integer = integer
    }

    /**
    Ctor

    - parameters:
        - integer: just an integer
    */
    public convenience init(integer: Int) {
        self.init(integer: { integer })
    }

    /**
    - returns:
    Integer represented by the computation

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Int {
        return try integer()
    }

}