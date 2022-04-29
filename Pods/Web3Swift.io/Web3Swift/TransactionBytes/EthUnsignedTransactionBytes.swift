//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthUnsignedTransactionBytes.swift
//
// Created by Vadim Koleoshkin on 24/07/2018
//

import Foundation

/** Unsigned transaction bytes */
public final class EthUnsignedTransactionBytes: BytesScalar {
    
    private let origin: BytesScalar
    
    /**
     Ctor
     
     - parameters:
     - networkID: id of a network where the transaction is to be deployed
     - transactionsCount: count of all transactions previously sent by the sender
     - gasPrice: gas price in Wei
     - gasEstimate: estimate for gas needed for transaction to be mined
     - recipientAddress: address of a recipient
     - weiAmount: amount to be sent in wei
     - contractCall: a bytes representation of the ABI call to the contract
     */
    public init(
        networkID: IntegerScalar,
        transactionsCount: BytesScalar,
        gasPrice: BytesScalar,
        gasEstimate: BytesScalar,
        recipientAddress: BytesScalar,
        weiAmount: BytesScalar,
        contractCall: BytesScalar
    ) {
        self.origin = EthManuallyTransactionBytes(
            networkID: networkID,
            transactionsCount: transactionsCount,
            gasPrice: gasPrice,
            gasEstimate: gasEstimate,
            recipientAddress: recipientAddress,
            weiAmount: weiAmount,
            contractCall: contractCall,
            r: EmptyBytes(),
            s: EmptyBytes(),
            v: EthNumber(value: networkID)
        )
    }
    
    
    /**
     - returns:
     unsigned transaction as `Data`
     
     - throws:
     `DescribedError` if something went wrong
     */
    public func value() throws -> Data {
        return try origin.value()
    }
    
}
