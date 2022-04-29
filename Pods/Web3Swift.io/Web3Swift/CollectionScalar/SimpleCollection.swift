//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// SimpleCollection.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Anonymous collection scalar wrapper */
public final class SimpleCollection<T>: CollectionScalar<T> {

    private let collection: () throws -> (AnyCollection<T>)

    /**
    Ctor

    - parameters:
        - collection: a closure representing a type erased collection of elements
    */
    public init(collection: @escaping () throws -> (AnyCollection<T>)) {
        self.collection = collection
    }

    /**
    Ctor

    - parameters:
        - collection: a closure representing an array as a collection of elements
    */
    // swiftlint:disable:next attributes
    public convenience init(collection: @escaping () throws -> ([T])) {
        self.init(collection: { try AnyCollection(collection()) })
    }

    /**
    Ctor

    - parameters:
        - collection: an array of elements
    */
    public convenience init(collection: [T]) {
        self.init(collection: { collection })
    }

    /**
    - returns:
    An `Array` representation of collection of elements

    - throws:
    `DescribedError` if something went wrong
    */
    public override func value() throws -> [T] {
        return try Array(
            collection()
        )
    }

}
