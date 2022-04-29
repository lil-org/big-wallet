//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// PendingBlockChainState.swift
//
// Created by Vadim Koleoshkin on 8/06/2018
//

import Foundation

public final class ExactBlockChainState: BlockChainState {
    
    private let number: BytesScalar
    
    /**
     Ctor
     
     - parameters:
        - number: number to be converted to parameter
     */
    public init(number: BytesScalar) {
        self.number = number
    }
    
    
    /**
     Ctor
     
     - parameters:
        - number: `Int` representing number of the block
     */
    public convenience init(number: Int) {
        self.init(
            number: EthNumber(
                value: number
            )
        )
    }
    
    /**
     Ctor
     
     - parameters:
        - hex: `StringScalar` representing bytes of the block number in hex format
     */
    public convenience init(hex: StringScalar) {
        self.init(
            number: BytesFromHexString(
                hex: hex
            )
        )
    }
    
    /**
     Ctor
     
     - parameters:
        - hex: `String` representing bytes of the block number in hex format
     */
    public convenience init(hex: String) {
        self.init(
            hex: SimpleString{
                hex
            }
        )
    }
    
    /**
     - returns:
     Prefixed hexed `String` representation of a block number
     
     - throws:
     `DescribedError` if something went wrong
     */
    public func toString() throws -> String {
        return try HexPrefixedString(
            origin: CompactHexString(
                bytes: number
            )
        ).value()
    }
    
}
