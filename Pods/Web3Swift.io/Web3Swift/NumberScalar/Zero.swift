//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// Zero.swift
//
// Created by Vadim Koleoshkin on 23/04/2019
//

import Foundation

/** Unsigned big endian zero number */
public final class Zero: BytesScalar {
    
    private let zero: BytesScalar = EthNumber(value: 0)

    /**
    Ctor
    */
    public init() {
    }
    
    /**
     - returns:
        Bytes representation of a zero ethereum number
     */
    public func value() throws -> Data {
        return try zero.value()
    }
    
}
