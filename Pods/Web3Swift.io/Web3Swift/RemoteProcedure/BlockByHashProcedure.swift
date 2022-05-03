//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// BlockByHashProcedure.swift
//
// Created by Vadim Koleoshkin on 21/05/2019
//

import Foundation
import SwiftyJSON

/** Procedure for fetching block by hash */
public final class BlockByHashProcedure: RemoteProcedure {
    
    private let network: Network
    private let blockHash: BytesScalar
    
    /**
     Ctor
     
     - parameters:
     - network: network to ask for transaction
     - blockHash: hash of the raw block
     */
    public init(
        network: Network,
        blockHash: BytesScalar
    ) {
        self.network = network
        self.blockHash = blockHash
    }
    
    /**
     - returns:
     `JSON` representation of the block
     
     - throws:
     `DescribedError` if something went wrong
     */
    public func call() throws -> JSON {
        return try JSON(
            data: network.call(
                method: "eth_getBlockByHash",
                params: [
                    BytesParameter(bytes: blockHash),
                    BooleanParameter(value: true)
                ]
            )
        )
    }
    
}
