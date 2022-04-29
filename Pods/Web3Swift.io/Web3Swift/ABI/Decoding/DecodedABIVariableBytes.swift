//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// DecodedABIVariableBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Decoded bytes of variable length */
public final class DecodedABIVariableBytes: BytesScalar {

    private let abiMessage: CollectionScalar<BytesScalar>
    private let index: IntegerScalar

    public init(
        abiMessage: CollectionScalar<BytesScalar>,
        index: IntegerScalar
    ) {
        self.abiMessage = abiMessage
        self.index = index
    }

    /**
    Ctor

    - parameters:
        - abiMessage: message where bytes are located
        - index: position of the bytes
    */
    public convenience init(
        abiMessage: CollectionScalar<BytesScalar>,
        index: Int
    ) {
        self.init(
            abiMessage: abiMessage,
            index: SimpleInteger(
                integer: index
            )
        )
    }

    /**
    - returns:
    Decoded variable bytes

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        let abiTuple = self.abiMessage
        let offsetsCount: IntegerScalar = IntegersQuotient(
            dividend: EthInteger(
                hex: BytesAt(
                    collection: abiTuple,
                    index: index
                )
            ),
            divisor: SimpleInteger(
                integer: 32
            )
        )
        let bytesLength: IntegerScalar = EthInteger(
            hex: BytesAt(
                collection: abiTuple,
                index: offsetsCount
            )
        )
        return try FirstBytes(
            origin: ConcatenatedBytes(
                bytes: GeneratedCollection<BytesScalar>(
                    element: { index in
                        BytesAt(
                            collection: abiTuple,
                            index: IntegersSum(
                                terms: [
                                    SimpleInteger(
                                        integer: index + 1
                                    ),
                                    offsetsCount
                                ]
                            )
                        )
                    },
                    times: IntegersQuotient(
                        dividend: IntegersSum(
                            terms: [
                                bytesLength,
                                SimpleInteger(
                                    integer: 31
                                )
                            ]
                        ),
                        divisor: SimpleInteger(
                            integer: 32
                        )
                    )
                )
            ),
            length: bytesLength
        ).value()
    }

}
