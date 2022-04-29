//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// TransactionsCount.swift
//
// Created by Timofey Solonin on 16/05/2018
//

import Foundation

public final class TransactionsCount: BytesScalar {

    private let transactions: Transactions
    public init(transactions: Transactions) {
        self.transactions = transactions
    }

    public func value() throws -> Data {
        return try transactions.count().value()
    }

}