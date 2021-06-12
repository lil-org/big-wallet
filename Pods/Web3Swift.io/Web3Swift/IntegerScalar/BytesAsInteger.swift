//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// BytesAsInteger.swift
//
// Created by Timofey Solonin on 22/05/2018
//

import Foundation

internal final class IntegerBytesOverflowError: DescribedError {

    private let bytes: Data
    private let sizeLimit: Int
    public init(bytes: Data, sizeLimit: Int) {
        self.bytes = bytes
        self.sizeLimit = sizeLimit
    }

    internal var description: String {
        return "Integer with hex representation \(bytes.toHexString()) exceeds maximum size \(sizeLimit) by \(bytes.count - sizeLimit)"
    }

}

/** Bytes converted to an integer as a big endian, two's complement representation */
public final class BytesAsInteger: IntegerScalar {

    private let hex: BytesScalar

    /**
    Ctor

    - parameters:
        - hex: bytes to convert to integer
    */
    public init(hex: BytesScalar) {
        self.hex = TrimmedZeroPrefixBytes(
            origin: hex
        )
    }

    /**
    - returns:
    Integer reconstructed with bytes in big endian order

    - throws:
    `DescribedError` if something went wrong. I.e. if bytes count was higher than could be fit into Int
    */
    public func value() throws -> Int {
        let hex = try self.hex.value()
        guard hex.count <= MemoryLayout<Int>.size else {
            throw IntegerBytesOverflowError(
                bytes: hex,
                sizeLimit: MemoryLayout<Int>.size
            )
        }
        var integer = Int(0).bigEndian
        hex.forEach{ byte in
            integer = integer << 8
            integer = integer | Int(byte)
        }
        return integer
    }

}