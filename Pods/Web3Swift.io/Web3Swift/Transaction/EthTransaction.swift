//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthTransaction.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

/** A transaction from the blockchain */
public final class EthTransaction: Transaction {

    private let transaction: JSON
    
    private let network: Network

    public init(
        transaction: JSON,
        network: Network
    ) {
        self.transaction = transaction
        self.network = network
    }

    /**
    - returns:
    Number of transactions deployed by sender before this one

    - throws:
    `DescribedError` if something went wrong
    */
    public func nonce() throws -> BytesScalar {
        return try EthNumber(
            hex: transaction["nonce"].string()
        )
    }
    
    public func blockHash() throws -> BlockHash {
        return try EthBlockHash(
            hex: transaction["blockHash"].string(),
            network: network
        )
    }
    
    public func from() throws -> EthAddress {
        return try EthAddress(
            hex: transaction["from"].string()
        )
    }
    
    public func gas() throws -> EthNumber {
        return try EthNumber(
            hex: transaction["gas"].string()
        )
    }
    
    public func gasPrice() throws -> EthNumber {
        return try EthNumber(
            hex: transaction["gasPrice"].string()
        )
    }
    
    public func hash() throws -> TransactionHash {
        return try EthTransactionHash(
            transactionHash: BytesFromHexString(
                hex: transaction["hash"].string()
            ),
            network: network
        )
    }
    
    public func input() throws -> BytesScalar {
        return try BytesFromHexString(
            hex: transaction["input"].string()
        )
    }
    
    public func to() throws -> EthAddress {
        return try EthAddress(
            hex: transaction["to"].string()
        )
    }
    
    public func value() throws -> EthNumber {
        return try EthNumber(
            hex: transaction["value"].string()
        )
    }
}
