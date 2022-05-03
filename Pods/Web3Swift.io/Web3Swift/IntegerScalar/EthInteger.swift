//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthInteger.swift
//
// Created by Timofey Solonin on 16/05/2018
//

import Foundation

/** Ethereum int256 translated into Swift native integer. Note that any negative integer is expected to be represented as two's complement of 256 bit size. */
public final class EthInteger: IntegerScalar {

    private let int: IntegerScalar

    /**
    Ctor

    - parameters:
        - hex: hexadecimal representation of the integer in big endian, two's complement, 256 bit format.
    */
    public init(hex: BytesScalar) {
        self.int = TernaryInteger(
            if: IsNegativeEthInteger(
                hex: hex
            ),
            then: BytesAsInteger(
                hex: LeftPaddedBytes(
                    origin: Trimmed255PrefixBytes(
                        origin: hex
                    ),
                    element: SimpleInteger(
                        integer: 0xff
                    ),
                    length: IntegerTypeSize()
                )
            ),
            else: NaturalInteger(
                origin: BytesAsInteger(
                    hex: TrimmedZeroPrefixBytes(
                        origin: hex
                    )
                )
            )
        )
    }

    /**
    Ctor

    - parameters:
        - hex: hexadecimal representation of the integer in big endian, two's complement, 256 bit format.
    */
    public convenience init(hex: StringScalar) {
        self.init(
            hex: BytesFromCompactHexString(
                hex: hex
            )
        )
    }

    /**
    Ctor

    - parameters:
        - hex: hexadecimal representation of the integer in big endian, two's complement, 256 bit format.
    */
    public convenience init(hex: String) {
        self.init(
            hex: SimpleString(
                string: hex
            )
        )
    }

    /**
    - returns:
    Integer value represented by the hexadecimal

    - throws:
    `DescribedError` if something went wrong. I.e. if ethereum integer did not fit into platform integer.
    */
    public func value() throws -> Int {
        return try self.int.value()
    }

}
