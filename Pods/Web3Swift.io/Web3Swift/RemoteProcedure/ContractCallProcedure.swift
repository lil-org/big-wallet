//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ContractCallProcedure.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

/** A call to the contract function */
final public class ContractCallProcedure: RemoteProcedure {

    private let network: Network
    private let parameters: [String: EthParameter]

    /**
    Ctor

    - parameters:
        - network: network to call
        - parameters: parameters of the contract call
    */
    public init(
        network: Network,
        parameters: [String: EthParameter]
    ) {
        self.network = network
        self.parameters = parameters
    }

    /**
    - returns:
    `JSON` for the call result

    - throws:
    `DescribedError` if something went wrong
    */
    public func call() throws -> JSON {
        return try JSON(
            data: network.call(
                method: "eth_call",
                params: [
                    ObjectParameter(
                        dictionary: parameters
                    ),
                    TagParameter(
                        state: PendingBlockChainState()
                    )
                ]
            )
        )
    }

}
