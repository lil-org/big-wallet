//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// TrimmedPrefixBytes.swift
//
// Created by Timofey Solonin on 19/05/2018
//

import Foundation

/** Bytes without leading element */
public final class TrimmedPrefixBytes: BytesScalar {

    private let origin: BytesScalar
    private let prefix: IntegerScalar

    /**
    Ctor

    - parameters:
        - origin: bytes to trim
        - prefix: byte to trim the origin off
    */
    public init(
        origin: BytesScalar,
        prefix: IntegerScalar
    ) {
        self.origin = origin
        self.prefix = RangeConstrainedInteger(
            origin: prefix,
            minimum: 0,
            maximum: 255
        )
    }

    /**
    - returns:
    Bytes without the specified element in the lead (last byte is not considered leading).
    */
    public func value() throws -> Data {
        let origin = try self.origin.value()
        let prefix = try self.prefix.value()
        return origin.dropLast().drop(while: { $0 == prefix }) + [origin.last].compactMap{ $0 }
    }

}