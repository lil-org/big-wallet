//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EmptyBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Just empty bytes */
public final class EmptyBytes: BytesScalar {

    /**
    Ctor
    */
    public init() {
    }

    /**
    - returns:
    Empty bytes as `Data`

    - throws:
    Doesn't throw
    */
    public func value() throws -> Data {
        return Data([])
    }

}
