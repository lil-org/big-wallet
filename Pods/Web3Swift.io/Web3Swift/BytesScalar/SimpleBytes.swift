//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// SimpleBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import CryptoSwift
import Foundation

/** Anonymous class for evaluating bytes */
public final class SimpleBytes: BytesScalar {

    private let bytes: () throws -> (Data)

    /**
    Ctor

    - parameters:
        - valueComputation: closure which returns bytes as `Data`
    */
    public init(bytes: @escaping () throws -> (Data)) {
        self.bytes = bytes
    }

    /**
    Ctor

    - parameters:
        - bytes: bytes as `Data` to be wrapped into scalar
    */
    public convenience init(bytes: Data) {
        self.init(bytes: { bytes })
    }

    public convenience init(bytes: CollectionScalar<UInt8>) {
        self.init(
            bytes: {
                try Data(
                    bytes.value()
                )
            }
        )
    }

    /**
    Ctor

    - parameters:
        - bytes: bytes as `[UInt8]` to be wrapped into scalar
    */
    public convenience init(bytes: [UInt8]) {
        self.init(
            bytes: SimpleCollection(
                collection: bytes
            )
        )
    }

    /**
    - returns:
    bytes represented as `Data`

    - throws:
    `DescribedError` if something goes wrong.
    */
    public func value() throws -> Data {
        return try bytes()
    }

}
