//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ABIVariableBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

public final class ABIVariableBytes: ABIEncodedParameter {

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
        - offset: number of elements preceding the variable bytes tails

    - returns:
    A collection with a single element representing a distance from the beginning of the encoding to the tails of the variable bytes
    */
    public func heads(offset: Int) throws -> [BytesScalar] {
        return [
            LeftZeroesPaddedBytes(
                origin: SimpleBytes{
                    try EthNumber(
                        value: offset * 32
                    ).value()
                },
                length: 32
            )
        ]
    }

    //TODO: This implementation is not lazy and is difficult to understand
    /**
    - parameters:
        - offset: invariant for tails

    - returns:
    A collection with bytes count followed by the bytes
    */
    public func tails(offset: Int) throws -> [BytesScalar] {
        let origin = try self.origin.value()
        return [
            LeftZeroesPaddedBytes(
                origin: EthNumber(
                    value: origin.count
                ),
                length: 32
            )
        ] + Array(origin.enumerated())
            .splitAt{ index, _ in
                (index + 1) % 32 == 0
            }
            .map{ splitBytes in
                splitBytes.map{ _, bytes in
                    bytes
                }
            }
            .map{ bytes in
                RightZeroesPaddedBytes(
                    origin: SimpleBytes(
                        bytes: bytes
                    ),
                    padding: 32
                )
            }
    }

    /**
    - returns:
    true
    */
    public func isDynamic() -> Bool {
        return true
    }

    /**
    - returns:
    1
    */
    public func headsCount() -> Int {
        return 1
    }

}
