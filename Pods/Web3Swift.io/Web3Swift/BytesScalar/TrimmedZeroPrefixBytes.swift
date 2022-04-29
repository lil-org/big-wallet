//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// TrimmedZeroPrefixBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Bytes without leading zeroes */
public final class TrimmedZeroPrefixBytes: BytesScalar {

    private let origin: BytesScalar
    /**
    Ctor

    - parameters:
        - origin: bytes to trim
    */
    public init(origin: BytesScalar) {
        self.origin = TrimmedPrefixBytes(
            origin: origin,
            prefix: SimpleInteger(
                integer: 0
            )
        )
    }

    /**
    - returns:
    bytes as `Data` without leading zeroes (last value in case it is zero is not considered leading)

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try origin.value()
    }

}
