//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// Int.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

extension Int {

    internal func unsignedByteWidth() -> Int {
        return (self.bitWidth - self.leadingZeroBitCount - 1) / 8 + 1
    }

    /**
    Tells if Int is even (divisible by 2 with 0 as a remainder)

    - returns:
    true if even, false if odd
    */
    internal func isEven() -> Bool {
        return self % 2 == 0
    }

}
