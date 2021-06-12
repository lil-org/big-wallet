//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// RLPCollectionsAppendix.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

public final class RLPCollectionAppendix: RLPAppendix {

    public func applying(to bytes: Data) throws -> Data {
        return try RLPStandardAppendix(
            offset: 0xc0
        ).applying(to: bytes)
    }

}
