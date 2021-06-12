//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// BytesAt.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Bytes at a collection of bytes */
public final class BytesAt: BytesScalar {

    private let element: ElementAt<BytesScalar>

    /**
    Ctor

    - parameters:
        - collection: a collection of bytes scalars
        - index: index of the bytes scalar
    */
    public init(
        collection: CollectionScalar<BytesScalar>,
        index: IntegerScalar
    ) {
        self.element = ElementAt(
            collection: collection,
            index: index
        )
    }

    /**
    Ctor

    - parameters:
        - collection: a collection of bytes scalars
        - index: index of the bytes scalar
    */
    public convenience init(
        collection: CollectionScalar<BytesScalar>,
        index: Int
    ) {
        self.init(
            collection: collection,
            index: SimpleInteger(
                integer: index
            )
        )
    }

    /**
    - returns:
    Bytes at the specified index.

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try element.value().value()
    }

}
