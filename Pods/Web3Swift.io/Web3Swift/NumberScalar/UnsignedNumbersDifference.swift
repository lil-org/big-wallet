//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// UnsignedNumbersDifference.swift
//
// Created by Timofey Solonin on 23/05/2018
//

import BigInt
import Foundation

/** A difference of unsigned big endian numbers of arbitrary length */
public final class UnsignedNumbersDifference: BytesScalar {

    private let minuend: BytesScalar
    private let subtrahend: BytesScalar

    /**
    Ctor

    - parameters:
        - minuend: integer to subtract from
        - subtrahend: integer to subtract
    */
    public init(
        minuend: BytesScalar,
        subtrahend: BytesScalar
    ) {
        self.minuend = minuend
        self.subtrahend = subtrahend
    }

    /**
    - returns:
    Difference between minuend and subtrahend as minuend - subtrahend
    */
    public func value() throws -> Data {
        return try BigUInt(
            minuend.value()
        ).subtractSafely(
            subtrahend: BigUInt(
                subtrahend.value()
            )
        ).serialize()
    }

}
