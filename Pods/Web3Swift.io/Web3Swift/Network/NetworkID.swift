//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// NetworkID.swift
//
// Created by Timofey Solonin on 16/05/2018
//

import Foundation

public final class NetworkID: IntegerScalar {

    private let network: Network
    public init(network: Network) {
        self.network = network
    }

    public func value() throws -> Int {
        return try network.id().value()
    }

}