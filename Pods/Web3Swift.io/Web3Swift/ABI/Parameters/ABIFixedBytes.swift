//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ABIFixedBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Fixed length bytes (up to 32) encoded as an ABI parameter */
public final class ABIFixedBytes: ABIEncodedParameter {

    private let origin: BytesScalar

    /**
    Ctor

    - parameters:
        - origin: bytes to be encoded
    */
    public init(origin: BytesScalar) {
        self.origin = origin
    }

    /**
    - parameters:
        - offset: fixed bytes are invariant

    - returns:
    A collection with a single element representing an ABI encoded boolean value.
    */
    public func heads(offset: Int) throws -> [BytesScalar] {
        return [
            FixedLengthBytes(
                origin: RightZeroesPaddedBytes(
                    origin: origin,
                    padding: 32
                ),
                length: 32
            )
        ]
    }

    /**
    - parameters:
        - offset: fixed bytes are invariant

    - returns:
    Empty collection
    */
    public func tails(offset: Int) throws -> [BytesScalar] {
        return []
    }

    /**
    - returns:
    false
    */
    public func isDynamic() -> Bool {
        return false
    }

    /**
    - returns:
    1
    */
    public func headsCount() -> Int {
        return 1
    }
    
}
