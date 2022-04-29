//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// FirstBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** First n or less bytes of a bytes sequence */
final public class FirstBytes: BytesScalar {

    private let origin: BytesScalar
    private let length: IntegerScalar

    /**
    Ctor

    - parameters:
        - origin: bytes to take prefix of
        - length: maximum length of the prefix
    */
    public init(
        origin: BytesScalar,
        length: IntegerScalar
    ) {
        self.origin = origin
        self.length = length
    }

    /**
    Ctor

    - parameters:
        - origin: bytes to take prefix of
        - length: maximum length of the prefix
    */
    public convenience init(
        origin: BytesScalar,
        length: Int
    ) {
        self.init(
            origin: origin,
            length: SimpleInteger(
                integer: length
            )
        )
    }

    /**
    - returns:
    Bytes represented as `Data` of size length or less

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try origin
            .value()
            .prefix(
                Int(
                    try length.value()
                )
            )
    }

}
