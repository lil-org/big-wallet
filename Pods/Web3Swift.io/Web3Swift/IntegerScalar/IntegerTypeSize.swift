//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// IntegerTypeSize.swift
//
// Created by Timofey Solonin on 22/05/2018
//

import Foundation

/** Int size in bytes. */
public final class IntegerTypeSize: IntegerScalar {

    /**
    - returns:
    Int size in bytes. I.e. Int64 is 8 bytes and Int32 is 7 bytes.
    */
    public func value() throws -> Int {
        return MemoryLayout<Int>.size
    }

}