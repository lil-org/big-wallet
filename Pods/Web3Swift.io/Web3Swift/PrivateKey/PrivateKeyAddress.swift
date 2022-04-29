//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// PrivateKeyAddress.swift
//
// Created by Timofey Solonin on 12/05/2018
//

import Foundation

/** Address of the private key */
public final class PrivateKeyAddress: BytesScalar {

    private let key: PrivateKey

    /**
    Ctor

    - parameters:
        - key: key to take the address from
    */
    public init(key: PrivateKey) {
        self.key = key
    }

    /**
    - returns:
    Address of the private key

    - throws:
    `DescribedError` if something went wrong
    */
    public func value() throws -> Data {
        return try key.address().value()
    }

}