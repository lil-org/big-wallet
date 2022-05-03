//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// TransactionReceipt.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Receipt associated with the transaction */
public protocol TransactionReceipt {

    func blockHash() throws -> BlockHash
    
    func cumulativeUsedGasAmount() throws -> EthNumber
    
    /**
    - returns:
    Gas amount that was used up by the transaction

    - throws:
    `DescribedError if something went wrong`
    */
    func usedGasAmount() throws -> BytesScalar
    
    /**
     - returns:
        Collection of logs emmited in transaction
     
     - throws:
        `DescribedError if something went wrong`
     */
    func logs() throws -> CollectionScalar<TransactionLog>

}
