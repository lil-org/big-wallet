//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// TransactionProcedure.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

/** Procedure for fetching transaction */
public final class TransactionProcedure: RemoteProcedure {

    private let network: Network
    private let transactionHash: BytesScalar

    /**
    Ctor

    - parameters:
        - network: network to ask for transaction
        - transactionHash: hash of the raw transaction
    */
    public init(
        network: Network,
        transactionHash: BytesScalar
    ) {
        self.network = network
        self.transactionHash = transactionHash
    }

    /**
    - returns:
    `JSON` representation of the transaction

    - throws:
    `DescribedError` if something went wrong
    */
    public func call() throws -> JSON {
        return try JSON(
            data: network.call(
                method: "eth_getTransactionByHash",
                params: [
                    BytesParameter(bytes: transactionHash)
                ]
            )
        )
    }

}
