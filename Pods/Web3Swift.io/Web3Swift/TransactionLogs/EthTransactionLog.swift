//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthTransactionLog.swift
//
// Created by Vadim Koleoshkin on 14/05/2019
//

import Foundation
import SwiftyJSON

internal final class InvalidTopicsCount: DescribedError {
    
    internal var description: String {
        return "Log does not contain signature"
    }
    
}

public final class EthTransactionLog: TransactionLog {
    
    private let log: JSON
    private let network: Network
    
    public init(serializedLog: JSON, network: Network) {
        self.log = serializedLog
        self.network = network
    }
    
    public func signature() throws -> BytesScalar {
        let topics = try self.topics()
        if topics.isEmpty {
            throw InvalidTopicsCount()
        }
        return topics[0]
    }
    
    public func topics() throws -> [BytesScalar] {
        return try log["topics"].array().map {
            try BytesFromHexString(hex: $0.string())
        }
    }
    
    public func data() throws -> ABIMessage {
        return try ABIMessage(
            message: log["data"].string()
        )
    }
    
    
    public func index() throws -> EthNumber {
        return try EthNumber(
            hex: log["logIndex"].string()
        )
    }
    
    public func removed() throws -> BooleanScalar {
        return try SimpleBoolean(
            bool: log["removed"].bool()
        )
    }
    
    public func address() throws -> EthAddress {
        return try EthAddress(
            hex: log["address"].string()
        )
    }
    
    public func transactionHash() throws -> TransactionHash {
        return try EthTransactionHash(
            transactionHash: BytesFromHexString(
                hex: log["transactionHash"].string()
            ),
            network: network
        )
    }
    
    public func blockHash() throws -> BlockHash {
        return try EthBlockHash(
            hex: log["blockHash"].string(),
            network: network
        )
    }
    
    public func blockNumber() throws -> EthNumber {
        return try EthNumber(
            hex: log["blockNumber"].string()
        )
    }
    
    public func transactionIndex() throws -> EthNumber {
        return try EthNumber(
            hex: log["transactionIndex"].string()
        )
    }
}
