//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// Data.swift
//
// Created by Vadim Koleoshkin on 11/05/2019
//

import Foundation

extension Data {
    
    public func toDecimal() throws -> Decimal {
        return try DecimalFromHex(
            hex: SimpleBytes(
                bytes: self
            )
        ).value()
    }
    
    public func toNormalizedDecimal(power: Int) throws -> Decimal {
        return try NormalizedDecimalFromHex(
            hex: SimpleBytes(
                bytes: self
            ),
            power: power
        ).value()
    }
    
    public func toDecimalString() throws -> String {
        return try HexAsDecimalString(
            hex: SimpleBytes(
                bytes: self
            )
        ).value()
    }
    
    public func toPrefixedHexString() -> String {
        return "0x" + self.toHexString()
    }

}
