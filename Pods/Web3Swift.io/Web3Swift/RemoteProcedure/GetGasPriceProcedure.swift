//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// GetGasPriceProcedure.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

public class GetGasPriceProcedure: RemoteProcedure {
    
    private var network: Network
    
    public init(network: Network) {
        self.network = network
    }
    
    public func call() throws -> JSON {
        return try JSON(
            data: network.call(
                method: "eth_gasPrice",
                params: []
            )
        )
    }
    
}
