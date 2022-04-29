//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// CachedCollection.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Permanently cached collection */
public final class CachedCollection<T>: CollectionScalar<T> {

    private let origin: StickyComputation<[T]>

    /**
    Ctor

    - parameters:
        - origin: origin to cache
    */
    public init(
        origin: CollectionScalar<T>
    ) {
        self.origin = StickyComputation{ try origin.value() }
    }

    /**
    - returns:
    Cached collection as `Array` of `T`

    - throws:
    `DescribedError` if something went wrong
    */
    public override func value() throws -> [T] {
        return try origin.result()
    }

}
