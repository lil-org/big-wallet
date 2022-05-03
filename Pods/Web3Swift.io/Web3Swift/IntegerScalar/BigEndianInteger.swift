//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// BigEndianInteger.swift
//
// Created by Timofey Solonin on 16/05/2018
//

import Foundation

/** Big endian representation of an integer */
public final class BigEndianInteger: IntegerScalar {

    private let origin: IntegerScalar

    /**
    Ctor

    - parameters:
        - origin: origin to take big endian representation from
    */
    public init(origin: IntegerScalar) {
        self.origin = origin
    }

    /**
    - returns:
    Integer with a big endian binary representation. On a little endian platform it will be an integer with its bytes reversed.
    */
    public func value() throws -> Int {
        return try origin.value().bigEndian
    }

}