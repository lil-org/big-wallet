//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// SizeConstrainedCollection.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

internal final class IndexOutOfBoundsError: DescribedError {

    private let collectionSize: Int
    private let index: Int

    public init(
        collectionSize: Int,
        index: Int
    ) {
        self.collectionSize = collectionSize
        self.index = index
    }

    internal var description: String {
        return "Index \(index) is out of bounds in a collection of size \(collectionSize)"
    }

}

/** Collection constrained in its size */
public final class SizeConstrainedCollection<T>: CollectionScalar<T> {

    private let origin: CollectionScalar<T>
    private let minimum: IntegerScalar

    /**
    Ctor

    - parameters:
        - origin: origin to constraint in size
        - minimum: minimum number of elements expected in the collection
    */
    public init(
        origin: CollectionScalar<T>,
        minimum: IntegerScalar
    ) {
        self.origin = origin
        self.minimum = minimum
    }

    /**
    Ctor

    - parameters:
        - origin: origin to constraint in size
        - minimum: minimum number of elements expected in the collection
    */
    public convenience init(
        origin: CollectionScalar<T>,
        minimum: Int
    ) {
        self.init(
            origin: origin,
            minimum: SimpleInteger(
                integer: minimum
            )
        )
    }

    /**
    - returns:
    A collection with a size of at least `minimum`

    - throws:
    `DescribedError` if something went wrong. I.e. if size of the collection was less than `minimum`.
    */
    public override func value() throws -> [T] {
        let origin = try self.origin.value()
        let minimum = try self.minimum.value()
        guard origin.count >= Int(minimum) else {
            throw IndexOutOfBoundsError(
                collectionSize: Int(origin.count),
                index: minimum
            )
        }
        return origin
    }

}
