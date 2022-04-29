//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// Trimmed255PrefixBytes.swift
//
// Created by Timofey Solonin on 19/05/2018
//

import Foundation

/** Bytes without leading ffs */
public final class Trimmed255PrefixBytes: BytesScalar {

    private let origin: BytesScalar

    /**
    Ctor

    - parameters:
        - origin: bytes to trim
    */
    public init(
        origin: BytesScalar
    ) {
        self.origin = TrimmedPrefixBytes(
            origin: origin,
            prefix: SimpleInteger(
                integer: 255
            )
        )
    }

    /**
    - returns:
    Bytes without leading ffs (last byte is not considered leading)
    */
    public func value() throws -> Data {
        return try origin.value()
    }

}