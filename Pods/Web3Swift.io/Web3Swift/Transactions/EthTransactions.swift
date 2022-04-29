//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthTransactions.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

public final class EthTransactions: Transactions {

    private let procedure: RemoteProcedure
    public init(network: Network, address: BytesScalar, blockChainState: BlockChainState) {
        self.procedure = GetTransactionsCountProcedure(
            network: network,
            address: address,
            blockChainState: blockChainState
        )
    }

    public func count() throws -> BytesScalar {
        let transactionsCountProcedure = self.procedure
        return EthNumber(
            hex: SimpleString{
                try transactionsCountProcedure.call()["result"].string()
            }
        )
    }

}
