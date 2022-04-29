//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// TransactionLog.swift
//
// Created by Vadim Koleoshkin on 14/05/2019
//

import Foundation

public protocol TransactionLog {
    
    func signature() throws -> BytesScalar
    
    func topics() throws -> [BytesScalar]
    
    func data() throws -> ABIMessage
    
    func index() throws -> EthNumber
    
    func removed() throws -> BooleanScalar
    
    func address() throws -> EthAddress
    
    func transactionHash() throws -> TransactionHash
    
    func blockHash() throws -> BlockHash
    
    func blockNumber() throws -> EthNumber
    
    func transactionIndex() throws -> EthNumber
    
}
