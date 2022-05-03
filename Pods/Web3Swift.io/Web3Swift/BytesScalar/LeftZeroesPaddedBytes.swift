//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// LeftZeroesPaddedBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Pads bytes with zeroes to the left */
public final class LeftZeroesPaddedBytes: BytesScalar {

    private let origin: BytesScalar

    /**
    Ctor

    - parameters:
        - origin: bytes to pad
        - padding: size to which to pad to
    */
    public init(
        origin: BytesScalar,
        length: Int
    ) {
        self.origin = LeftPaddedBytes(
            origin: origin,
            element: SimpleInteger(
                integer: 0x00
            ),
            length: SimpleInteger(
                integer: length
            )
        )
    }

    /**
    - returns:
    Bytes as `Data` padded with zeroes to the right

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try origin.value()
    }

}
