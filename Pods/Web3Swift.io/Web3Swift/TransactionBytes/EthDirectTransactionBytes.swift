//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthDirectTransactionBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Bytes of a signed transaction to ethereum address */
public final class EthDirectTransactionBytes: BytesScalar {

    private let origin: BytesScalar

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
    */
    public init(
        networkID: IntegerScalar,
        transactionsCount: BytesScalar,
        gasPrice: BytesScalar,
        gasEstimate: BytesScalar,
        senderKey: PrivateKey,
        recipientAddress: BytesScalar,
        weiAmount: BytesScalar
    ) {
        self.origin = EthTransactionBytes(
            networkID: networkID,
            transactionsCount: transactionsCount,
            gasPrice: gasPrice,
            gasEstimate: gasEstimate,
            senderKey: senderKey,
            recipientAddress: recipientAddress,
            weiAmount: weiAmount,
            contractCall: EmptyBytes()
        )
    }

    /**
    Ctor

    - parameters:
        - network: Network where transaction is to be deployed
        - senderKey: private key of a sender
        - recipientAddress: address of a recipient
        - weiAmount: amount to be sent in wei
    */
    public convenience init(
        network: Network,
        senderKey: PrivateKey,
        recipientAddress: BytesScalar,
        weiAmount: BytesScalar
    ) {
        let senderAddress = CachedBytes(
            origin: SimpleBytes{
                try senderKey.address().value()
            }
        )
        let gasPrice = CachedBytes(
            origin: EthGasPrice(
                network: network
            )
        )
        self.init(
            networkID: CachedInteger(
                origin: NetworkID(
                    network: network
                )
            ),
            transactionsCount: CachedBytes(
                origin: EthNumber(
                    hex: SimpleBytes{
                        try EthTransactions(
                            network: network,
                            address: senderAddress,
                            blockChainState: PendingBlockChainState()
                        ).count().value()
                    }
                )
            ),
            gasPrice: gasPrice,
            gasEstimate: CachedBytes(
                origin: EthGasEstimate(
                    network: network,
                    senderAddress: senderAddress,
                    recipientAddress: recipientAddress,
                    gasPrice: gasPrice,
                    weiAmount: weiAmount
                )
            ),
            senderKey: senderKey,
            recipientAddress: recipientAddress,
            weiAmount: weiAmount
        )
    }

    /**
    - returns:
    Bytes of the encoded transaction as `Data`
    */
    public func value() throws -> Data {
        return try origin.value()
    }

}
