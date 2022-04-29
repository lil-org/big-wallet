//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthBlockHash.swift
//
// Created by Vadim Koleoshkin on 20/05/2019
//

import Foundation

/** Standard 32 bytes ethereum block hash */
public final class EthBlockHash: BlockHash {
    
    private let bytes: BytesScalar
    
    private let network: Network
    
    /**
     Ctor
     
     - parameters:
        - bytes: `BytesScalar` with a `value` count of 32
        - network: `Network` to fetch from JSON-RPC node
     */
    public init(bytes: BytesScalar, network: Network) {
        self.bytes = FixedLengthBytes(
            origin: bytes,
            length: 32
        )
        self.network = network
    }
    
    /**
     Ctor
     
     - parameters:
        - hex: `StringScalar` representing bytes of the block hash in hex format
        - network: `Network` to fetch from JSON-RPC node
     */
    public convenience init(hex: StringScalar, network: Network) {
        self.init(
            bytes: BytesFromHexString(
                hex: hex
            ),
            network: network
        )
    }
    
    /**
     Ctor
     
     - parameters:
        - hex: `String` representing bytes of the block hash in hex format
        - network: `Network` to fetch from JSON-RPC node
     */
    public convenience init(hex: String, network: Network) {
        self.init(
            hex: SimpleString{
                hex
            },
            network: network
        )
    }
    
    /**
     Bytes representation of ethereum block hash
     
     - returns:
     32 bytes `Data`
     
     - throws:
     `DescribedError` if something went wrong (i.e. bytes are not length 32)
     */
    public func value() throws -> Data {
        return try bytes.value()
    }
    
    /**
     Block representation of ethereum block hash
     
     - returns:
     `Block` object
     
     - throws:
     `DescribedError` if something went wrong 
     */
    public func block() throws -> Block {
        return try EthBlock(
            block: BlockByHashProcedure(
                network: network,
                blockHash: bytes
            ).call()["result"],
            network: network
        )
    }
    
}
