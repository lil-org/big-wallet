//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// LeftPaddedBytes.swift
//
// Created by Timofey Solonin on 22/05/2018
//

import Foundation

/** Bytes padded with an element to the left */
public final class LeftPaddedBytes: BytesScalar {

    private let origin: BytesScalar
    private let element: IntegerScalar
    private let length: IntegerScalar

    /**
    Ctor

    - parameters:
        - origin: bytes to pad
        - element: byte to pad with
        - length: length to pad to
    */
    public init(
        origin: BytesScalar,
        element: IntegerScalar,
        length: IntegerScalar
    ) {
        self.origin = origin
        self.element = RangeConstrainedInteger(
            origin: element,
            minimum: 0,
            maximum: Int(
                UInt8.max
            )
        )
        self.length = NaturalInteger(
            origin: length
        )
    }

    /**
    - returns:
    Original bytes sequence with element added to the left such that length of the new sequence mod(`length`) is 0
    */
    public func value() throws -> Data {
        let origin = try self.origin.value()
        let element = try UInt8(
            self.element.value()
        )
        let length = try self.length.value()
        return try ConcatenatedBytes(
            bytes: [
                SimpleBytes(
                    bytes: Data(
                        repeating: element,
                        count: (length - (origin.count % length)) % length
                    )
                ),
                SimpleBytes(
                    bytes: origin
                )
            ]
        ).value()
    }

}