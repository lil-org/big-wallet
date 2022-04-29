//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// DecodedABIBoolean.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Boolean decoded from an abi message */
public final class DecodedABIBoolean: BooleanScalar {

    private let origin: BooleanScalar

    /**
    Ctor

    - parameters:
        - abiMessage: message where boolean is located
        - index: position of the boolean
    */
    public init(
        abiMessage: CollectionScalar<BytesScalar>,
        index: Int
    ) {
        self.origin = NumericBoolean(
            bool: DecodedABINumber(
                abiMessage: abiMessage,
                index: index
            )
        )
    }

    /**
    - returns:
    Boolean decoded from the message

    - throws:
    `DescribedError` if something went wrong. I.e. if value at the specified index did not represent a boolean
    */
    public func value() throws -> Bool {
        return try origin.value()
    }

}
