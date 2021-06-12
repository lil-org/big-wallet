//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// GetTransactionsCountProcedure.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

public class GetTransactionsCountProcedure: RemoteProcedure {

    private var network: Network
    private var address: BytesScalar
    private var blockChainState: BlockChainState

    public init(network: Network, address: BytesScalar, blockChainState: BlockChainState) {
        self.network = network
        self.address = address
        self.blockChainState = blockChainState
    }

    public func call() throws -> JSON {
        return try JSON(
            data: network.call(
                method: "eth_getTransactionCount",
                params: [
                    BytesParameter(
                        bytes: address
                    ),
                    TagParameter(state: blockChainState)
                ]
            )
        )
    }

}
