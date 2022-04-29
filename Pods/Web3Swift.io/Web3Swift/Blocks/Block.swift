//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// Block.swift
//
// Created by Vadim Koleoshkin on 20/05/2019
//

import Foundation

//FIXME: Block description is not full
/** Representation of Block mined on Ethereum blockchain */
public protocol Block {
    
    /**
     - returns:
     block number represented as `EthNumber`
     */
    func number() throws -> EthNumber
    
    /**
     - returns:
     block hash represented as `BlockHash`
     */
    func hash() throws -> BlockHash
    
    /**
     - returns:
     blocks parent hash represented as `BlockHash`
     */
    func parentHash() throws -> BlockHash
   
    /**
     - returns:
     UNIX timestamp of block represented as `EthNumber`
     */
    func timestamp() throws -> EthNumber
    
    /**
     - returns:
     List of transactions `Transaction` mined in the block 
     */
    func transactions() throws -> CollectionScalar<Transaction>
    
}
