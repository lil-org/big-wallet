//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// DecodedABINumber.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Decoded number */
public final class DecodedABINumber: BytesScalar {

    private let number: BytesScalar

    /**
    Ctor

    - parameters:
        - abiMessage: message where number is located
        - index: position of the number
    */
    public init(
        abiMessage: CollectionScalar<BytesScalar>,
        index: Int
    ) {
        self.number = EthNumber(
            hex: BytesAt(
                collection: abiMessage,
                index: index
            )
        )
    }

    /**
    - returns:
    Compact hex representation of a decoded number

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try number.value()
    }

}
