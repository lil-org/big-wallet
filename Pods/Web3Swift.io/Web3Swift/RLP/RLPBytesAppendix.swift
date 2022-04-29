//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// RLPBytesAppendix.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

public final class RLPBytesAppendix: RLPAppendix {

    public func applying(to bytes: Data) throws -> Data {
        switch bytes.count {
        case 1 where try bytes.single() < 0x80:
            return bytes
        default:
            return try RLPStandardAppendix(
                offset: 0x80
            ).applying(to: bytes)
        }
    }

}
