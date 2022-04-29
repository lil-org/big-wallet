//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// BalanceProcedure.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

/** Procedure for fetching balance at the address */
public final class BalanceProcedure: RemoteProcedure {

    private let network: Network
    private let address: BytesScalar
    private let state: BlockChainState

    /**
    Ctor

    - parameters:
        - network: network to ask for balance
        - address: address to ask the balance for
        - state: state at which the balance of the address is to be asked
    */
    public init(
        network: Network,
        address: BytesScalar,
        state: BlockChainState
    ) {
        self.network = network
        self.address = address
        self.state = state
    }

    /**
    - returns:
    `JSON` representation of the balance

    - throws:
    `DescribedError` if something went wrong
    */
    public func call() throws -> JSON {
        return try JSON(
            data: network.call(
                method: "eth_getBalance",
                params: [
                    BytesParameter(bytes: address),
                    TagParameter(state: state)
                ]
            )
        )
    }

}
