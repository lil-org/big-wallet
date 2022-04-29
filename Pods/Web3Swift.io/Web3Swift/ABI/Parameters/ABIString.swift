//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ABIString.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** String value encoded as an ABI parameter */
public final class ABIString: ABIEncodedParameter {

    private let origin: ABIEncodedParameter

    /**
    Ctor

    - parameters:
        - origin: string to be encoded
    */
    public init(origin: StringScalar) {
        self.origin = ABIVariableBytes(
            origin: UTF8StringBytes(
                string: origin
            )
        )
    }

    /**
    - parameters:
        - offset: number of elements preceding the string tails

    - returns:
    A collection with a single element representing a distance from the beginning of the encoding to the tails of the string
    */
    public func heads(offset: Int) throws -> [BytesScalar] {
        return try origin.heads(offset: offset)
    }

    /**
    - parameters:
        - offset: invariant for tails

    - returns:
    A collection of encoded bytes from utf8 representation of a string prefixed by the length of the string in utf8 representation
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
