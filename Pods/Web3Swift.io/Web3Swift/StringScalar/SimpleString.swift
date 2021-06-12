//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// SimpleString.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Anonymous string scalar wrapper */
public final class SimpleString: StringScalar {

    private let computation: () throws -> (String)

    /**
    Ctor

    - parameters:
        - computation: computation that produces a `String` representation of a string
    */
    public init(computation: @escaping () throws -> (String)) {
        self.computation = computation
    }

    /**
    Ctor

    - parameters:
        - string: `String` to be wrapped into scalar
    */
    public convenience init(string: String) {
        self.init(computation: { string })
    }

    /**
    - returns:
    `String` representation of a string scalar

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> String {
        return try computation()
    }

}
