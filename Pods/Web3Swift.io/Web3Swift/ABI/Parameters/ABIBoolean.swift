//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ABIBoolean.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Boolean value encoded as an ABI parameter */
public final class ABIBoolean: ABIEncodedParameter {

    private let origin: ABIEncodedParameter

    /**
    Ctor

    - parameters:
        - origin: `Bool` representation of a boolean value
    */
    public init(origin: Bool) {
        self.origin = ABIFixedBytes(
            origin: LeftZeroesPaddedBytes(
                origin: SimpleBytes{
                    if origin {
                        return Data(
                            [0x01]
                        )
                    } else {
                        return Data(
                            [0x00]
                        )
                    }
                },
                length: 32
            )
        )
    }

    /**
    - parameters:
        - offset: boolean is invariant

    - returns:
    A collection with a single element representing an ABI encoded boolean value.
    */
    public func heads(offset: Int) throws -> [BytesScalar] {
        return try origin.heads(offset: offset)
    }

    /**
    - parameters:
        - offset: boolean is invariant

    - returns:
    Empty collection.
    */
    public func tails(offset: Int) throws -> [BytesScalar] {
        return try origin.tails(offset: offset)
    }

    /**
    - returns:
    true
    */
    public func isDynamic() -> Bool {
        return origin.isDynamic()
    }

    /**
    - returns:
    1
    */
    public func headsCount() -> Int {
        return 1
    }
    
}
