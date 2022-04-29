//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ABIAddress.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Address encoded as an ABI parameter */
public final class ABIAddress: ABIEncodedParameter {

    private let address: ABIEncodedParameter

    //TODO: Should EthAddress defensive decorator be here?
    /**
    Ctor

    - parameters:
        - address: ethereum address represented as bytes
    */
    public init(address: BytesScalar) {
        self.address = ABIFixedBytes(
            origin: FixedLengthBytes(
                origin: LeftZeroesPaddedBytes(
                    origin: EthAddress(
                        bytes: address
                    ),
                    length: 32
                ),
                length: 32
            )
        )
    }

    /**
    - parameters:
        - offset: address is invariant

    - returns:
    A collection with a single element representing an ABI encoded ethereum address.

    - throws:
    `DescribedError` if something went wrong
    */
    public func heads(offset: Int) throws -> [BytesScalar] {
        return try address.heads(offset: offset)
    }

    /**
    - parameters:
        - offset: address is invariant

    - returns:
    Empty collection.

    - throws:
    `DescribedError` if something went wrong
    */
    public func tails(offset: Int) throws -> [BytesScalar] {
        return try address.tails(offset: offset)
    }

    /**
    - returns:
    true
    */
    public func isDynamic() -> Bool {
        return address.isDynamic()
    }

    /**
    - returns: 
    1
    */
    public func headsCount() -> Int {
        return 1
    }

}
