//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// SizeBufferedBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Bytes buffered into collection elements by a size predicate */
public final class SizeBufferedBytes: CollectionScalar<BytesScalar> {

    private let origin: BytesScalar
    private let size: IntegerScalar

    /**
    Ctor

    - parameters:
        - origin: origin to buffer
        - size: maximum size of each element
    */
    public init(
        origin: BytesScalar,
        size: IntegerScalar
    ) {
        self.origin = origin
        self.size = size
    }

    /**
    Ctor

    - parameters:
        - origin: origin to buffer
        - size: maximum size of each element
    */
    public convenience init(
        origin: BytesScalar,
        size: Int
    ) {
        self.init(
            origin: origin,
            size: SimpleInteger(
                integer: size
            )
        )
    }

    /**
    - returns:
    A collection of bytes sequences buffered up to the specified `size`

    - throws:
    `DescribedError` if something went wrong
    */
    public override func value() throws -> [BytesScalar] {
        return try Array(self.origin.value().enumerated())
            .splitAt{ index, _ in
                try (index + 1) % Int(size.value()) == 0
            }
            .map{ enumeratedOrigin in
                SimpleBytes(
                    bytes: enumeratedOrigin.map{ _, origin in
                        origin
                    }
                )
            }
    }

}
