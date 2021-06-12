//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ReversedBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Bytes in reversed order */
public final class ReversedBytes: BytesScalar {

    private let origin: BytesScalar

    /**
    Ctor

    - parameters:
        - origin: origin to reverse
    */
    public init(origin: BytesScalar) {
        self.origin = origin
    }

    /**
    - returns:
    Bytes of the origin in reversed order

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try Data(
            origin.value().reversed()
        )
    }

}
