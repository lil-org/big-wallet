//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// CollectionSuffix.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Suffix (last n elements) of a collection */
public final class CollectionSuffix<T>: CollectionScalar<T> {

    private let origin: CollectionScalar<T>
    private let from: IntegerScalar

    /**
    Ctor

    - parameters:
        - origin: origin to suffix of minimum size `from` + 1
        - from: index to suffix from
    */
    public init(
        origin: CollectionScalar<T>,
        from: IntegerScalar
    ) {
        self.origin = origin
        self.from = from
    }

    /**
    - returns:
    All elements after and including the specified index

    - throws:
    `DescribedError` if something went wrong
    */
    public override func value() throws -> [T] {
        let from: Int = try self.from.value()
        return try Array(
            SizeConstrainedCollection(
                origin: origin,
                minimum: from + 1
            ).value()
                .suffix(
                    from: Int(
                        from
                    )
                )
        )
    }

}
