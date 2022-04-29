//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthContractCallBytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** Bytes of a signed contract function call transaction */
public final class EthContractCallBytes: BytesScalar {

    private let origin: BytesScalar

    /**
    Ctor

    - parameters:
        - networkID: id of a network where the transaction is to be deployed
        - transactionsCount: count of all transactions previously sent by the sender
        - gasPrice: gas price in Wei
        - gasEstimate: estimate for gas needed for transaction to be mined
        - senderKey: private key of a sender
        - contractAddress: address of the recipient contract
        - weiAmount: amount to be sent in wei
        - functionCall: encoded function call
    */
    public init(
        networkID: IntegerScalar,
        transactionsCount: BytesScalar,
        gasPrice: BytesScalar,
        gasEstimate: BytesScalar,
        senderKey: PrivateKey,
        contractAddress: BytesScalar,
        weiAmount: BytesScalar,
        functionCall: BytesScalar
    ) {
        self.origin = EthTransactionBytes(
            networkID: networkID,
            transactionsCount: transactionsCount,
            gasPrice: gasPrice,
            gasEstimate: gasEstimate,
            senderKey: senderKey,
            recipientAddress: contractAddress,
            weiAmount: weiAmount,
            contractCall: functionCall
        )
    }

    /**
    Ctor

    - parameters:
        - network: network where transaction is to be deployed
        - senderKey: private key of a sender
        - contractAddress: address of the recipient contract
        - weiAmount: amount to be sent in wei
        - functionCall: encoded function call
    */
    public convenience init(
        network: Network,
        senderKey: PrivateKey,
        contractAddress: BytesScalar,
        weiAmount: BytesScalar,
        functionCall: BytesScalar
    ) {
        let gasPrice = CachedBytes(
            origin: EthGasPrice(
                network: network
            )
        )
        self.init(
            network: network,
            gasPrice: gasPrice,
            senderKey: senderKey,
            contractAddress: contractAddress,
            weiAmount: weiAmount,
            functionCall: functionCall
        )
    }

    /**
    Ctor

    - parameters:
        - network: network where transaction is to be deployed
        - gasPrice: gas price in Wei
        - senderKey: private key of a sender
        - contractAddress: address of the recipient contract
        - weiAmount: amount to be sent in wei
        - functionCall: encoded function call
    */
    public convenience init(
        network: Network,
        gasPrice: BytesScalar,
        senderKey: PrivateKey,
        contractAddress: BytesScalar,
        weiAmount: BytesScalar,
        functionCall: BytesScalar
    ) {
        let senderAddress = CachedBytes(
            origin: SimpleBytes{
                try senderKey.address().value()
            }
        )
        let contractAddress = CachedBytes(
            origin: contractAddress
        )
        let functionCall = CachedBytes(
            origin: functionCall
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
                    recipientAddress: contractAddress,
                    gasEstimate: EthGasEstimate(
                        network: network,
                        senderAddress: senderAddress,
                        recipientAddress: contractAddress,
                        gasPrice: gasPrice,
                        weiAmount: weiAmount,
                        contractCall: functionCall
                    ),
                    gasPrice: gasPrice,
                    weiAmount: weiAmount,
                    contractCall: functionCall
                )
            ),
            senderKey: senderKey,
            contractAddress: contractAddress,
            weiAmount: weiAmount,
            functionCall: functionCall
        )
    }

    /**
    - returns:
    Bytes of the encoded abi function call as `Data`
    */
    public func value() throws -> Data {
        return try origin.value()
    }

}
