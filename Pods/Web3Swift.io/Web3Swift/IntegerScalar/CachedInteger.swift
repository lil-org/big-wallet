//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// CachedNumber.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Permanently cached integer */
public final class CachedInteger: IntegerScalar {

    private let stickyInt: StickyComputation<Int>

    /**
    - parameters:
        - origin: integer to cache
    */
    public init(origin: IntegerScalar) {
        self.stickyInt = StickyComputation<Int>{
            try origin.value()
        }
    }

    /**
    - returns:
    `Int` representation of cached origin

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Int {
        return try stickyInt.result()
    }

}
