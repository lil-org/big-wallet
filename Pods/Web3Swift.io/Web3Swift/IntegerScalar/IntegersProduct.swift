//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// IntegersProduct.swift
//
// Created by Timofey Solonin on 17/05/2018
//

import Foundation

/** Product of integers */
public final class IntegersProduct: IntegerScalar {

    private let terms: CollectionScalar<Int>

    /**
    Ctor

    - parameters:
        - terms: terms to multiply
    */
    public init(terms: CollectionScalar<IntegerScalar>) {
        self.terms = MappedCollection(
            origin: terms,
            mapping: { try $0.value() }
        )
    }

    /**
    Ctor

    - parameters:
        - terms: terms to multiply
    */
    public convenience init(terms: [IntegerScalar]) {
        self.init(
            terms: SimpleCollection<IntegerScalar>(
                collection: terms
            )
        )
    }

    /**
    Ctor

    - parameters:
        - terms: terms to multiply
    */
    public convenience init(terms: [Int]) {
        self.init(
            terms: MappedCollection(
                origin: SimpleCollection(
                    collection: terms
                ),
                mapping: { SimpleInteger(integer: $0) }
            )
        )
    }

    /**
    - returns:
    Product of terms T as (T1 * T2 * T3 ... * Tn)

    - throws:
    `DescribedError` if something went wrong. I.e. if product results in an overflow.
    */
    public func value() throws -> Int {
        return try terms.value().reduce(Int(1)) { token, value in
            try token.multiplySafely(by: value)
        }
    }

}