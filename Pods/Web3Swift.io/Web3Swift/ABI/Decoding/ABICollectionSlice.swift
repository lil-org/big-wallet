//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ABICollectionSlice.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** A slice of an non typed abi dynamic collection */
public final class ABICollectionSlice: CollectionScalar<BytesScalar> {

    private let abiMessage: CollectionScalar<BytesScalar>
    private let index: Int

    /**
    Ctor

    - parameters:
        - abiMessage: message containing the collection
        - index: position of the collection
    */
    public init(
        abiMessage: CollectionScalar<BytesScalar>,
        index: Int
    ) {
        self.abiMessage = abiMessage
        self.index = index
    }

    /**
        Right now collection slice grabs everything after the length of the
        dynamic collection which means that it grabs every parameter encoded
        into a message after itself. This is irrelevant when decoding but may
        be a problem in the future.
    */
    /**
    - returns:
    Non typed content of the collection.

    - throws:
    `DescribedError` if something went wrong
    */
    public override func value() throws -> [BytesScalar] {
        return try CollectionSuffix(
            origin: abiMessage,
            from: IntegersSum(
                terms: [
                    IntegersQuotient(
                        dividend: EthInteger(
                            hex: BytesAt(
                                collection: abiMessage,
                                index: index
                            )
                        ),
                        divisor: SimpleInteger(
                            integer: 32
                        )
                    ),
                    SimpleInteger(
                        integer: 1
                    )
                ]
            )
        ).value()
    }

}
