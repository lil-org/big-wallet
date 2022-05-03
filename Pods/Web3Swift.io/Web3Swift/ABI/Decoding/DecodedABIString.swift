//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// DecodedABIString.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Decoded variable bytes interpreted as a utf8 string */
public final class DecodedABIString: StringScalar {

    private let origin: StringScalar

    /**
    Ctor

    - parameters:
        - abiMessage: message where string is located
        - index: position of the string
    */
    public init(
        abiMessage: CollectionScalar<BytesScalar>,
        index: Int
    ) {
        self.origin = UTF8String(
            bytes: DecodedABIVariableBytes(
                abiMessage: abiMessage,
                index: index
            )
        )
    }

    /**
    - returns:
    Decoded string

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> String {
        return try self.origin.value()
    }

}
