//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// DecimalFromHex.swift
//
// Created by Vadim Koleoshkin on 09/05/2019
//

import Foundation

/** Hexadecimal unsigned big endian number represented as a Decimal number */
public final class DecimalFromHex: DecimalScalar {
    
    private let hex: BytesScalar
    
    public init(hex: BytesScalar) {
        self.hex = hex
    }
    
    /**
     - returns:
     Decimal representation of a hexadecimal
     */
    public func value() throws -> Decimal {
        guard let value = try Decimal(
            string: HexAsDecimalString(
                hex: self.hex
            ).value()
        ) else {
            throw HexToDecimalConversionError(
                hex: try self.hex.value().toHexString()
            )
        }
        return value;
    }
    
}


public final class HexToDecimalConversionError: DescribedError {
    
    private let hex: String
    
    public init(hex: String) {
        self.hex = hex
    }
    
    public var description: String {
        return "Unable to convert hex string \"\(hex)\" to decimal"
    }
    
}
