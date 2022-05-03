//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// Account.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

/** An account that is associated with some private key on the network */
public protocol Account {

    /**
    TODO: I am not sure whether the Account should promise to return its balance in wei
    - returns:
    The amount of value the `Account` holds

    - throws:
    `DescribedError` if something went wrong
    */
    func balance() throws -> BytesScalar

    /**
    Send the specified amount to the recipient

    - parameters:
        - weiAmount: amount to be sent in wei
        - recipientAddress: address of the recipient

    - returns:
    `TransactionHash` identifier of the transaction

    - throws:
    `DescribedError` if something went wrong
    */
    func send(weiAmount: BytesScalar, to recipientAddress: BytesScalar) throws -> TransactionHash

}
