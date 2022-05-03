//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// DecodedABIAddress.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Ethereum address decoded from an abi message */
public final class DecodedABIAddress: BytesScalar {

    private let origin: BytesScalar

    /**
    Ctor

    - parameters:
        - abiMessage: message where address is located
        - index: position of the address
    */
    public init(
        abiMessage: CollectionScalar<BytesScalar>,
        index: Int
    ) {
        self.origin = EthAddress(
            bytes: NumberHex(
                number: DecodedABINumber(
                    abiMessage: abiMessage,
                    index: index
                )
            )
        )
    }

    /**
    - returns:
    Address decoded from the message

    - throws:
    `DescribedError` if something 
    */
    public func value() throws -> Data {
        return try origin.value()
    }

}
