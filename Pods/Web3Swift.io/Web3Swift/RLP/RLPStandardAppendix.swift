//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// RLPStandardAppendix.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

public final class BytesLengthOverflow: Swift.Error { }

internal final class RLPStandardAppendix: RLPAppendix {

    private let offset: UInt8
    public init(offset: UInt8) {
        self.offset = offset
    }

    internal func applying(to bytes: Data) throws -> Data {
        switch bytes.count {
        case 0...55:
            return Data(
                [
                    UInt8(
                        UInt8(bytes.count) + offset
                    )
                ]
            ) + bytes
        case 56...Int.max:
            return try Data(
                [
                    UInt8(bytes.count.unsignedByteWidth() + Int(offset) + 55)
                ]
            ) + TrimmedZeroPrefixBytes(
                origin: IntegerBytes(
                    value: bytes.count.bigEndian
                )
            ).value() + bytes
        default:
            throw BytesLengthOverflow()
        }
    }

}
