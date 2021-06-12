//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EncodedContract.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Encoded initialized contract bytes */
public final class EncodedContract: BytesScalar {

    private let byteCode: BytesScalar
    private let arguments: [ABIEncodedParameter]

    /**
    Ctor

    - parameters:
        - bytesCode: bytes code of the contract
        - arguments: arguments of the contract ctor
    */
    public init(
        byteCode: BytesScalar,
        arguments: [ABIEncodedParameter]
    ) {
        self.byteCode = byteCode
        self.arguments = arguments
    }

    /**
    - returns:
    Bytes representation of the initialized contract
    */
    public func value() throws -> Data {
        return try ConcatenatedBytes(
            bytes: [
                byteCode,
                EncodedABITuple(
                    parameters: arguments
                )
            ]
        ).value()
    }

}
