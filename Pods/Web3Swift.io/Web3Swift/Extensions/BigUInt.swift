//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// BigUInt.swift
//
// Created by Timofey Solonin on 23/05/2018
//

import BigInt
import Foundation

extension BigUInt {

    internal func subtractSafely(subtrahend: BigUInt) throws -> BigUInt {
        let difference = self.subtractingReportingOverflow(subtrahend)
        guard difference.overflow == false else {
            throw IntegerOverflow(
                firstTerm: self,
                secondTerm: subtrahend,
                operation: "subtraction"
            )
        }
        return difference.partialValue
    }

}