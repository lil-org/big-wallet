//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// FixedWidthInt.swift
//
// Created by Timofey Solonin on 23/05/2018
//

import Foundation

internal final class DivisionByZero: DescribedError {

    internal var description: String {
        return "Division by 0 is undefined"
    }

}

internal final class IntegerOverflow: DescribedError {

    private let firstTerm: CustomStringConvertible
    private let secondTerm: CustomStringConvertible
    private let operation: String

    internal init(firstTerm: CustomStringConvertible, secondTerm: CustomStringConvertible, operation: String) {
        self.firstTerm = firstTerm
        self.secondTerm = secondTerm
        self.operation = operation
    }

    internal var description: String {
        return "Operations of \(operation) called on \(firstTerm) with \(secondTerm) causes an overflow"
    }

}

extension FixedWidthInteger {

    internal func addSafely(with addend: Self) throws -> Self {
        let sum = self.addingReportingOverflow(addend)
        guard sum.overflow == false else {
            throw IntegerOverflow(
                firstTerm: self,
                secondTerm: addend,
                operation: "summation"
            )
        }
        return sum.partialValue
    }

    internal func subtractSafely(from minuend: Self) throws -> Self {
        let difference = minuend.subtractingReportingOverflow(self)
        guard difference.overflow == false else {
            throw IntegerOverflow(
                firstTerm: minuend,
                secondTerm: self,
                operation: "subtraction"
            )
        }
        return difference.partialValue
    }

    internal func multiplySafely(by multiplier: Self) throws -> Self {
        let multiplication = self.multipliedReportingOverflow(by: multiplier)
        guard multiplication.overflow == false else {
            throw IntegerOverflow(
                firstTerm: self,
                secondTerm: multiplier,
                operation: "multiplication"
            )
        }
        return multiplication.partialValue
    }

    internal func divideSafely(by divisor: Self) throws -> Self {
        guard divisor != 0 else {
            throw DivisionByZero()
        }
        let division = self.dividedReportingOverflow(by: divisor)
        guard division.overflow == false else {
            throw IntegerOverflow(
                firstTerm: self,
                secondTerm: divisor,
                operation: "division"
            )
        }
        return division.partialValue
    }

}