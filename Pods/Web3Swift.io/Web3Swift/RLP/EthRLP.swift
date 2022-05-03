//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthRLP.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/**
An encoding specific to ethereum quantities

Ethereum imposes a specific requirement on RLP encoding for quantities:
https://ethereum.stackexchange.com/questions/30518/does-rlp-specify-integer-encoding
*/
public final class EthRLP: RLP {

    private let number: BytesScalar

    /**
    Ctor
    
    - parameters: 
        - number: number to be encoded
    */
    public init(number: BytesScalar) {
        self.number = number
    }

    /**
    - returns:
    Bytes as `Data` representing RLP encoded ethereum quantity encoding 0 as empty byte array 
    
    - throws:
    `DescribedError` if something went wrong 
    */
    public func value() throws -> Data {
        let encodedNumber = try SimpleRLP(
            bytes: number.value()
        ).value()
        if encodedNumber == Data([0x00]) {
            return try SimpleRLP(
                bytes: []
            ).value()
        } else {
            return encodedNumber
        }
    }

}
