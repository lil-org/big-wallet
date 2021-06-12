//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// AlchemyNetwork.swift
//
// Created by Vadim Koleoshkin on 27/03/2019
//

import Foundation

/** alchemyapi.io network */
public final class AlchemyNetwork: Network {
    
    private let origin: GethNetwork
    
    /**
     Ctor
     
     - parameters:
     - chain: chain identifier
     - apiKey: api key for accessing JSON RPC calls
     */
    public init(chain: String, apiKey: String) {
        origin = GethNetwork(url: "https://eth-"+chain.lowercased()+".alchemyapi.io/v2/"+apiKey)
    }
    
    /**
     - returns:
     id of a network
     
     - throws:
     `DescribedError` if something went wrong
     */
    public func id() throws -> IntegerScalar {
        return try origin.id()
    }
    
    /**
     - returns:
     `Data` for a JSON RPC call
     
     - throws:
     `DescribedError` if something went wrong
     */
    public func call(method: String, params: Array<EthParameter>) throws -> Data {
        return try origin.call(method: method, params: params)
    }
    
}
