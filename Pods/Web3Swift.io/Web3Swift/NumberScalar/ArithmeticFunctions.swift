//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ArithmeticFunctions.swift
//
// Created by Timofey Solonin on 23/05/2018
//

import Foundation

public func -(left: BytesScalar, right: BytesScalar) -> BytesScalar {
    return UnsignedNumbersDifference(
        minuend: left,
        subtrahend: right
    )
}

public func +(left: BytesScalar, right: BytesScalar) -> BytesScalar {
    return UnsignedNumbersSum(
        terms: [
            left,
            right
        ]
    )
}

public func *(left: BytesScalar, right: BytesScalar) -> BytesScalar {
    return UnsignedNumbersProduct(
        terms: [
            left,
            right
        ]
    )
}

public func /(left: BytesScalar, right: BytesScalar) -> BytesScalar {
    return UnsignedNumbersQuotient(
        dividend: left,
        divisor: right
    )
}

public func ==(left: BytesScalar, right: BytesScalar) -> BooleanScalar {
    return UnsignedNumbersEquality(
        lhs: left,
        rhs: right
    )
}
