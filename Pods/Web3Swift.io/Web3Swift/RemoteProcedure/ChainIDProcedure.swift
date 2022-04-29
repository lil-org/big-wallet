//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// ChainIDProcedure.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

/** Identifier of the network */
public final class ChainIDProcedure: RemoteProcedure {

    private let network: Network

    /**
    Ctor

    - parameters:
        - network: network to ask for identifier
    */
    public init(network: Network) {
        self.network = network
    }

    /**
    - returns:
    `JSON` representation of the network id

    - throws:
    `DescribedError` if something went wrong
    */
    public func call() throws -> JSON {
        return try JSON(
            data: network.call(
                method: "net_version",
                params: []
            )
        )
    }

}
