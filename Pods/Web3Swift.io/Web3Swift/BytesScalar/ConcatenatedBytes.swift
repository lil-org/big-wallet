//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ConcatenatedBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Bytes concatenated into a single collection */
public final class ConcatenatedBytes: BytesScalar {

    private let bytes: CollectionScalar<BytesScalar>

    /**
    Ctor

    - parameters
        - bytes: a collection of bytes to be concatenated
    */
    public init(bytes: CollectionScalar<BytesScalar>) {
        self.bytes = bytes
    }

    /**
    Ctor

    - parameters
        - bytes: a collection of bytes to be concatenated
    */
    public convenience init(bytes: [BytesScalar]) {
        self.init(bytes: SimpleCollection(collection: bytes))
    }

    /**
    - returns:
    bytes as `Data` of the bytes collection with respect to their position in the collection

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try bytes.value().reduce(Data()) {
            try $0 + $1.value()
        }
    }

}
