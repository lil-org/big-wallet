//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// UnsignedNumbersSum.swift
//
// Created by Timofey Solonin on 23/05/2018
//

import BigInt
import Foundation

/** A sum of unsigned big endian numbers of arbitrary length */
public final class UnsignedNumbersSum: BytesScalar {

    private let terms: CollectionScalar<BigUInt>

    /**
    Ctor

    - parameters:
        - terms: terms to sum
    */
    public init(
        terms: CollectionScalar<BytesScalar>
    ) {
        self.terms = MappedCollection(
            origin: terms,
            mapping: { term in
                try BigUInt(
                    term.value()
                )
            }
        )
    }

    /**
    Ctor

    - parameters:
        - terms: terms to sum
    */
    public convenience init(
        terms: [BytesScalar]
    ) {
        self.init(
            terms: SimpleCollection(
                collection: terms
            )
        )
    }

    /**
    - returns:
    Sum of terms T as (T1 + T2 + T3 ... + Tn)
    */
    public func value() throws -> Data {
        return try terms.value().reduce(BigUInt(0)) { token, value in
            token + value
        }.serialize()
    }

}