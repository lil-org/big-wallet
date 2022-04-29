//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EnumeratedCollection.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** A collection of `T` numbering every element in the collection explicitly from 0 */
public final class EnumeratedCollection<T>: CollectionScalar<(Int, T)> {

    private let origin: CollectionScalar<T>

    /**
    Ctor

    - parameters:
        - origin: origin to enumerate
    */
    public init(
        origin: CollectionScalar<T>
    ) {
        self.origin = origin
    }

    /**
    - returns:
    A collection as `Array` of elements with each element represented as number and a value

    - throws:
    `DescribedError` if something went wrong
    */
    public override func value() throws -> [(Int, T)] {
        return try Array(
            origin.value().enumerated()
        )
    }

}
