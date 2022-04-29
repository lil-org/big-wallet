//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// SendRawTransactionProcedure.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

/** Procedure for sending transaction bytes */
public final class SendRawTransactionProcedure: RemoteProcedure {

    private let network: Network
    private let transactionBytes: BytesScalar

    /**
    Ctor

    - parameters:
        - network: network where to deploy transaction
        - transactionBytes: bytes of the transaction to be deployed
    */
    public init(
        network: Network,
        transactionBytes: BytesScalar
    ) {
        self.network = network
        self.transactionBytes = transactionBytes
    }

    /**
    - returns:
    bytes representation of the `TransactionHash`

    - throws:
    `DescribedError` if something went wrong
    */
    public func call() throws -> JSON {
        return try JSON(
            data: network.call(
                method: "eth_sendRawTransaction",
                params: [
                    BytesParameter(bytes: transactionBytes)
                ]
            )
        )
    }

}
