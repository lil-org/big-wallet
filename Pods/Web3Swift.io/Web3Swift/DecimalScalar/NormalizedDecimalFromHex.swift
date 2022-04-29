//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// NormalizedDecimalFromHex.swift
//
// Created by Vadim Koleoshkin on 10/05/2019
//

import Foundation

/** Hexadecimal unsigned big endian number represented as a Decimal number divided by 10^power */
public final class NormalizedDecimalFromHex: DecimalScalar {
    
    private let hex: BytesScalar
    private let power: Int
    
    public init(hex: BytesScalar, power: Int) {
        self.hex = hex
        self.power = power
    }
    
    /**
     - returns:
     Normalized Decimal representation of hexdecimal number
     */
    public func value() throws -> Decimal {
        return try DecimalFromHex(hex: hex).value() / pow(Decimal(10), power)
    }
    
}
