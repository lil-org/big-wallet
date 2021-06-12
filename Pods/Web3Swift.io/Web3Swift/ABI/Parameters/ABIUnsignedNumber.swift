//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ABIUnsignedNumber.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Unsigned number encoded as an ABI parameter */
public final class ABIUnsignedNumber: ABIEncodedParameter {

    private let origin: ABIEncodedParameter

    /**
    Ctor

    - parameters:
        - origin: number to encode
    */
    public init(origin: BytesScalar) {
        self.origin = ABIFixedBytes(
            origin: LeftZeroesPaddedBytes(
                origin: origin,
                length: 32
            )
        )
    }

    /**
    - parameters:
        - offset: unsigned number is invariant

    - returns:
    A collection with a single element representing an ABI encoded number.
    */
    public func heads(offset: Int) throws -> [BytesScalar] {
        return try origin.heads(offset: offset)
    }

    /**
    - parameters:
        - offset: unsigned number is invariant

    - returns:
    Empty collection
    */
    public func tails(offset: Int) throws -> [BytesScalar] {
        return try origin.tails(offset: offset)
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
