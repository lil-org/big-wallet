//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthManuallySignedTransactionBytes.swift
//
// Created by Vadim Koleoshkin on 24/07/2018
//

import CryptoSwift
import Foundation

/** Remotly signed transaction bytes */
public final class EthManuallyTransactionBytes: BytesScalar {
    
    private let networkID: IntegerScalar
    private let transactionsCount: BytesScalar
    private let gasPrice: BytesScalar
    private let gasEstimate: BytesScalar
    private let recipientAddress: BytesScalar
    private let weiAmount: BytesScalar
    private let contractCall: BytesScalar
    private let r: BytesScalar
    private let s: BytesScalar
    private let v: BytesScalar
    
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
     - r: bytes describe R point as defined in ecdsa
     - s: bytes describe S point as defined in ecdsa
     - v: bytes describe recovery point as defined in ecdsa and EIP-155
     */
    public init(
        networkID: IntegerScalar,
        transactionsCount: BytesScalar,
        gasPrice: BytesScalar,
        gasEstimate: BytesScalar,
        recipientAddress: BytesScalar,
        weiAmount: BytesScalar,
        contractCall: BytesScalar,
        r: BytesScalar,
        s: BytesScalar,
        v: BytesScalar
    ) {
        self.networkID = networkID
        self.transactionsCount = transactionsCount
        self.gasPrice = gasPrice
        self.gasEstimate = gasEstimate
        self.recipientAddress = recipientAddress
        self.weiAmount = weiAmount
        self.contractCall = contractCall
        self.r = r
        self.s = s
        self.v = v
    }
    
    /**
     - returns:
     signed transaction as `Data` that can be deployed for mining
     
     - throws:
     `DescribedError` if something went wrong
     */
    public func value() throws -> Data {
        return try SimpleRLP(
            rlps: [
                EthRLP(number: transactionsCount),
                EthRLP(number: gasPrice),
                EthRLP(number: gasEstimate),
                SimpleRLP(bytes: recipientAddress),
                EthRLP(number: weiAmount),
                SimpleRLP(bytes: contractCall),
                SimpleRLP(bytes: v),
                SimpleRLP(bytes: r),
                SimpleRLP(bytes: s),
            ]
        ).value()
    }
    
}
