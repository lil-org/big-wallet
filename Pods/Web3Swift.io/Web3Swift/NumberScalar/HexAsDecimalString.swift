//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// NumberAsDecimalString.swift
//
// Created by Timofey Solonin on 23/05/2018
//

import BigInt
import Foundation

/** Hexadecimal unsigned big endian number as a decimal number represented as string */
public final class HexAsDecimalString: StringScalar {

    private let hex: BytesScalar

    /**
    Ctor

    - parameters:
        - hex: hexadecimal representation of a number
    */
    public init(
        hex: BytesScalar
    ) {
        self.hex = hex
    }

    /**
    - returns:
    Decimal string representation of a hexadecimal representation
    */
    public func value() throws -> String {
        return try String(
            BigUInt(
                hex.value()
            ),
            radix: 10
        )
    }

}