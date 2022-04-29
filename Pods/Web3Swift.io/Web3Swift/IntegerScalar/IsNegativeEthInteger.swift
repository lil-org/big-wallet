//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// IsNegativeEthInteger.swift
//
// Created by Timofey Solonin on 19/05/2018
//

import Foundation

/** Boolean statement of whether a particular bytes collection represents a negative ethereum integer (int256, two's complement). */
public final class IsNegativeEthInteger: BooleanScalar {

    private let isNegative: BooleanScalar

    /**
    Ctor

    - parameters:
        - hex: representation of ethereum integer in big endian order
    */
    public init(hex: BytesScalar) {
        self.isNegative = And(
            conditions: [
                IntegersEquality(
                    lhs: SizeOf(
                        collection: BytesAsCollection(
                            origin: hex
                        )
                    ),
                    rhs: SimpleInteger(
                        integer: 32
                    )
                ),
                IntegersEquality(
                    lhs: FirstBit(
                        value: BigEndianInteger(
                            origin: FirstByte(
                                origin: hex
                            )
                        )
                    ),
                    rhs: SimpleInteger(
                        integer: 1
                    )
                )
            ]
        )
    }

    /**
    - returns:
    True if represents a negative, false if positive or 0
    */
    public func value() throws -> Bool {
        return try isNegative.value()
    }

}
