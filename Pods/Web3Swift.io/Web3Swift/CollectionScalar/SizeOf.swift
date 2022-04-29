//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// SizeOf.swift
//
// Created by Timofey Solonin on 19/05/2018
//

import Foundation

/** A size of a collection */
public final class SizeOf: IntegerScalar {
    
    private let collection: CollectionScalar<Any>

    /**
    Ctor

    - parameters:
        - collection: collection to count the length of
    */
    public init<T>(collection: CollectionScalar<T>) {
        self.collection = MappedCollection(
            origin: collection,
            mapping: { $0 as Any }
        )
    }

    /**
    - returns:
    Number of elements in the collection
    */
    public func value() throws -> Int {
        return try collection.value().count
    }

}