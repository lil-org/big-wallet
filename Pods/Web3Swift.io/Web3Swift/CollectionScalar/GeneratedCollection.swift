//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// GeneratedCollection.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Generated collection */
public final class GeneratedCollection<T>: CollectionScalar<T> {

    private let element: (_ index: Int) throws -> (T)
    private let times: IntegerScalar

    /**
    Ctor

    - parameters:
        - element: indexed element factory called up to `times` times
        - times: number of times to call the factory
    */
    public init(
        element: @escaping (_ index: Int) throws -> (T),
        times: IntegerScalar
    ) {
        self.element = element
        self.times = times
    }

    /**
    Ctor

    - parameters:
        - element: indexed element factory called up to `times` times
        - times: number of times to call the factory
    */
    public convenience init(
        element: @escaping (_ index: Int) throws -> (T),
        times: Int
    ) {
        self.init(
            element: element,
            times: SimpleInteger(
                integer: times
            )
        )
    }

    /**
    Ctor

    - parameters:
        - element: just an element that will be repeated
        - times: number of times to call the factory
    */
    public convenience init(
        element: T,
        times: Int
    ) {
        self.init(
            element: { _ in element },
            times: times
        )
    }

    /**
    - returns:
    A collection of generated element of size `times`

    - throws:
    `DescribedError` if something went wrong
    */
    public override func value() throws -> [T] {
        return try (0..<times.value()).map{ index in
            try element(index)
        }
    }

}
