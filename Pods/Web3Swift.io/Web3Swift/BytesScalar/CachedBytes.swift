//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// CachedBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Permanently cached bytes */
public final class CachedBytes: BytesScalar {

    private let stickyValue: StickyComputation<Data>

    /**
    - parameters:
        - origin: bytes to cache
    */
    public init(origin: BytesScalar) {
        self.stickyValue = StickyComputation{
            try origin.value()
        }
    }

    /**
    - returns:
    Bytes as `Data` of the cached origin

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try stickyValue.result()
    }

}
