//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// MappedCollection.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** A collection of elements mapped from `C` to `T` */
public final class MappedCollection<C, T>: CollectionScalar<T> {

    private let origin: CollectionScalar<C>
    private let mapping: (C) throws -> (T)

    /**
    Ctor

    - parameters:
        - origin: origin to map
        - mapping: closure for transforming `C` into `T`
    */
    public init(
        origin: CollectionScalar<C>,
        mapping: @escaping (C) throws -> (T)
    ) {
        self.origin = origin
        self.mapping = mapping
    }

    /**
    - returns:
    A collection of `T` as `Array`

    - throws:
    `DescribedError` if something went wrong
    */
    public override func value() throws -> [T] {
        return try origin.value().map{ c in
            try mapping(c)
        }
    }

}
