//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthTransactionBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import CryptoSwift
import Foundation

/** Signed transaction bytes */
public final class EthTransactionBytes: BytesScalar {

    private let networkID: IntegerScalar
    private let transactionsCount: BytesScalar
    private let gasPrice: BytesScalar
    private let gasEstimate: BytesScalar
    private let senderKey: PrivateKey
    private let recipientAddress: BytesScalar
    private let weiAmount: BytesScalar
    private let contractCall: BytesScalar

    /**
    Ctor

    - parameters:
        - networkID: id of a network where the transaction is to be deployed
        - transactionsCount: count of all transactions previously sent by the sender
        - gasPrice: gas price in Wei
        - gasEstimate: estimate for gas needed for transaction to be mined
        - senderKey: private key of a sender
        - recipientAddress: address of a recipient
        - weiAmount: amount to be sent in wei
        - contractCall: a bytes representation of the ABI call to the contract
    */
    internal init(
        networkID: IntegerScalar,
        transactionsCount: BytesScalar,
        gasPrice: BytesScalar,
        gasEstimate: BytesScalar,
        senderKey: PrivateKey,
        recipientAddress: BytesScalar,
        weiAmount: BytesScalar,
        contractCall: BytesScalar
    ) {
        self.networkID = networkID
        self.transactionsCount = transactionsCount
        self.gasPrice = gasPrice
        self.gasEstimate = gasEstimate
        self.senderKey = senderKey
        self.recipientAddress = recipientAddress
        self.weiAmount = weiAmount
        self.contractCall = contractCall
    }

    /**
    It should be noted that 35 is the magic number suggested by EIP155 https://github.com/ethereum/EIPs/blob/master/EIPS/eip-155.md

    - returns:
    signed transaction as `Data` that can be deployed for mining

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        let transactionParameters: [RLP] = [
            EthRLP(number: transactionsCount),
            EthRLP(number: gasPrice),
            EthRLP(number: gasEstimate),
            SimpleRLP(bytes: recipientAddress),
            EthRLP(number: weiAmount),
            SimpleRLP(bytes: contractCall)
        ]
        let signature = SECP256k1Signature(
            digest: Keccak256Bytes(
                origin: SimpleRLP(
                    rlps: transactionParameters + [
                        EthRLP(
                            number: EthNumber(
                                value: networkID
                            )
                        ),
                        SimpleRLP(bytes: []),
                        SimpleRLP(bytes: [])
                    ]
                )
            ),
            privateKey: senderKey
        )
        return try SimpleRLP(
            rlps: transactionParameters + [
                EthRLP(
                    number: EthNumber(
                        value: IntegersSum(
                            terms: SimpleCollection<IntegerScalar>(
                                collection: [
                                    IntegersProduct(
                                        terms: SimpleCollection(
                                            collection: [
                                                networkID,
                                                SimpleInteger(
                                                    integer: 2
                                                )
                                            ]
                                        )
                                    ),
                                    SimpleInteger(
                                        integer: 35
                                    ),
                                    signature.recoverID()
                                ]
                            )
                        )
                    )
                ),
                SimpleRLP(bytes: signature.r().value()),
                SimpleRLP(bytes: signature.s().value())
            ]
        ).value()
    }

}
