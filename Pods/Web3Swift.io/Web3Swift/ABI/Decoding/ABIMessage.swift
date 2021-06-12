//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ABIMessage.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** abi message represented as a collection of 32 bytes sequences */
public final class ABIMessage: CollectionScalar<BytesScalar> {

    private let message: CollectionScalar<BytesScalar>

    /**
    Ctor

    - parameters:
        - message: concatenated bytes of the abi message
    */
    public init(message: BytesScalar) {
        self.message = SizeConstrainedCollection(
            origin: MappedCollection(
                origin: SizeBufferedBytes(
                    origin: message,
                    size: 32
                ),
                mapping: {
                    FixedLengthBytes(
                        origin: $0,
                        length: 32
                    )
                }
            ),
            minimum: 1
        )
    }

    /**
    Ctor

    - parameters:
        - message: concatenated string representation of bytes of the abi message
    */
    public convenience init(message: StringScalar) {
        self.init(
            message: BytesFromHexString(
                hex: message
            )
        )
    }

    /**
    Ctor

    - parameters:
        - message: concatenated string representation of bytes of the abi message
    */
    public convenience init(message: String) {
        self.init(
            message: SimpleString(
                string: message
            )
        )
    }
    
    /**
     Ctor
     
     - parameters:
     - message: concatenated bytes of the abi message
     */
    public convenience init(message: Data) {
        self.init(
            message: SimpleBytes(
                bytes: message
            )
        )
    }

    /**
    - returns:
    A collection of sequences of bytes of length 32

    - throws:
    `DescribedError` if something went wrong. I.e. if collection was empty
    */
    public override func value() throws -> [BytesScalar] {
        return try message.value()
    }

}
