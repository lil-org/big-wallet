//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// TrailingCompactBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Bytes without trailing zeroes */
public final class TrailingCompactBytes: BytesScalar {

    private let compactOrigin: BytesScalar
    /**
    Ctor

    - parameters:
        - origin: bytes to be compacted
    */
    public init(origin: BytesScalar) {
        self.compactOrigin = ReversedBytes(
            origin: TrimmedZeroPrefixBytes(
                origin: ReversedBytes(
                    origin: origin
                )
            )
        )
    }

    /**
    - returns:
    bytes as `Data` without trailing zeroes (first value in case it is zero is not considered trailing)

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try compactOrigin.value()
    }

}
