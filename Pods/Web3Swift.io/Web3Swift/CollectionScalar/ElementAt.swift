//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ElementAt.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Element type T at an index in the collection */
public final class ElementAt<T> {

    private let collection: CollectionScalar<T>
    private let index: IntegerScalar

    /**
    Ctor

    - parameters:
        - collection: collection containing the element
        - index: position of the element in the collection
    */
    public init(
        collection: CollectionScalar<T>,
        index: IntegerScalar
    ) {
        self.collection = collection
        self.index = index
    }

    /**
    Ctor

    - parameters:
        - collection: collection containing the element
        - index: position of the element in the collection
    */
    public convenience init(
        collection: CollectionScalar<T>,
        index: Int
    ) {
        self.init(
            collection: collection,
            index: SimpleInteger(
                integer: index
            )
        )
    }

    /**
    - returns:
    Element type T at the specified index

    - throws:
    `DescribedError` if something went wrong. I.e. index was out of bounds
    */
    public func value() throws -> T {
        let index = try self.index.value()
        return try SizeConstrainedCollection(
            origin: self.collection,
            minimum: index + 1
        ).value()[Int(index)]
    }

}
