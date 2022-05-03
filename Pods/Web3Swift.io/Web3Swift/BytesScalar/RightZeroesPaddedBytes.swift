//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// RightZeroesPaddedBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Pads bytes with zeroes to the right */
public final class RightZeroesPaddedBytes: BytesScalar {

    private let origin: BytesScalar
    private let padding: Int

    /**
    Ctor

    - parameters:
        - origin: bytes to pad
        - padding: size to which to pad to
    */
    public init(
        origin: BytesScalar,
        padding: Int
    ) {
        self.origin = origin
        self.padding = padding
    }

    /**
    - returns:
    Bytes as `Data` padded with zeroes to the right

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        let origin = try self.origin.value()
        let padding = Int(self.padding)
        return try ConcatenatedBytes(
            bytes: [
                SimpleBytes(
                    bytes: origin
                ),
                SimpleBytes(
                    bytes: Data(
                        repeating: 0x00,
                        count: (padding - (origin.count % padding)) % padding
                    )
                )
            ]
        ).value()
    }

}
