//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// BytesParameter.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

public final class BytesParameter: EthParameter {

    private let bytes: BytesScalar

    /**
    Ctor

    - parameters:
        - bytes: unstructed data to be passed to network
    */
    public init(bytes: BytesScalar) {
        self.bytes = bytes
    }

    /**
    - returns:
    `String` representation of the unstructured bytes as specified by ethereum JSON RPC

    - throws:
    `DescribedError` is something went wrong
    */
    public func value() throws -> Any {
        return try PrefixedHexString(
            bytes: bytes
        ).value()
    }

}
