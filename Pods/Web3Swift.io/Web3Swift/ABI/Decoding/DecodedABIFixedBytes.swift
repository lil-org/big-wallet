//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// DecodedABIFixedBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Decoded bytes with fixed length (up to 32) */
public final class DecodedABIFixedBytes: BytesScalar {

    private let bytes: BytesScalar

    /**
    Ctor

    - parameters:
        - abiMessage: message where bytes are located
        - length: expected number of bytes
        - index: position of the bytes
    */
    public init(
        abiMessage: CollectionScalar<BytesScalar>,
        length: Int,
        index: Int
    ) {
        self.bytes = FirstBytes(
            origin: BytesAt(
                collection: abiMessage,
                index: index
            ),
            length: length
        )
    }

    /**
    - returns:
    Decoded bytes

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try bytes.value()
    }

}
