//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// FirstByte.swift
//
// Created by Timofey Solonin on 19/05/2018
//

import Foundation

/** First byte of a bytes sequence */
public final class FirstByte: IntegerScalar {

    private let origin: CollectionScalar<UInt8>

    /**
    Ctor

    - parameters:
        - origin: bytes to take first from
    */
    public init(origin: CollectionScalar<UInt8>) {
        self.origin = SizeConstrainedCollection(
            origin: origin,
            minimum: 1
        )
    }

    /**
    Ctor

    - parameters:
        - origin: bytes to take first from
    */
    public convenience init(origin: BytesScalar) {
        self.init(
            origin: BytesAsCollection(
                origin: origin
            )
        )
    }

    //swiftlint:disable force_unwrapping
    /**
    - returns:
    First byte of the bytes sequence

    - throws:
    `DescribedError` if something went wrong. I.e. if bytes were empty.
    */
    public func value() throws -> Int {
        return try Int(
            origin.value().first!
        )
    }

}