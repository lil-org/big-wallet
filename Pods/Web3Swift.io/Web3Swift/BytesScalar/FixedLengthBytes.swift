//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// FixedLengthBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

internal final class IncorrectBytesLengthError: DescribedError {

    private let length: Int
    private let bytes: Data
    public init(bytes: Data, length: Int) {
        self.bytes = bytes
        self.length = length
    }

    public var description: String {
        return "Received bytes of size \(bytes.count) when \(length) was expected"
    }

}

/** Bytes with a fixed length */
public final class FixedLengthBytes: BytesScalar {

    private let origin: BytesScalar
    private let length: Int

    /**
    Ctor

    - parameters:
        - origin: bytes to be evaluated
        - length: expected length
    */
    public init(origin: BytesScalar, length: Int) {
        self.origin = origin
        self.length = length
    }

    /**
    - returns:
    bytes as `Data` of the specified `length`

    - throws:
    `DescribedError` if something went wrong or if bytes were of different length than specified
    */
    public func value() throws -> Data {
        let bytes = try origin.value()
        guard bytes.count == length else {
            throw IncorrectBytesLengthError(
                bytes: bytes,
                length: length
            )
        }
        return bytes
    }

}
