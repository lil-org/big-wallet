//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthAutoAccount.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

/** Eth account that asks gas price and gas estimate from the network */
public final class EthAutoAccount: Account {

    private let network: Network
    private let privateKey: PrivateKey

    /**
    Ctor

    - parameters:
        - network: network to work with
        - privateKey: private key associated with the account
    */
    public init(
        network: Network,
        privateKey: PrivateKey
    ) {
        self.network = network
        self.privateKey = privateKey
    }

    /**
    - returns:
    Balance of the account in wei

    - throws:
    `DescribedError` if something went wrong
    */
    public func balance() throws -> BytesScalar {
        return try EthBalance(
            network: network,
            address: privateKey.address()
        )
    }

    //TODO: This DSL intentionally violates laziness by calling SendRawTransactionProcedure.call. This is definitely not OO. Maybe we can somehow split DSL and use it only as a procedural wrapper.
    /**
    Send value from this account to the recipient

    - parameters:
        - weiAmount: amount to be sent in wei
        - recipientAddress: address of the recipient

    - returns:
    `TransactionHash` identifier of the transaction

    - throws:
    `DescribedError` if something went wrong
    */
    public func send(weiAmount: BytesScalar, to recipientAddress: BytesScalar) throws -> TransactionHash {
        return try EthTransactionHash(
            transactionHash: BytesFromCompactHexString(
                hex: SimpleString(
                    string: SendRawTransactionProcedure(
                        network: network,
                        transactionBytes: EthDirectTransactionBytes(
                            network: network,
                            senderKey: privateKey,
                            recipientAddress: recipientAddress,
                            weiAmount: weiAmount
                        )
                    ).call()["result"].string()
                )
            ),
            network: network
        )
    }

}
