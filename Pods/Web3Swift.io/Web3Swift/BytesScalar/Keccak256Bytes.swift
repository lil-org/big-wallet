//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// Keccak256Bytes.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import CryptoSwift
import Foundation

/** Bytes digested by keccak256 algorithm */
public final class Keccak256Bytes: BytesScalar {

    private let origin: BytesScalar

    /**
    Ctor

    - parameters:
        - origin: bytes to digest
    */
    public init(origin: BytesScalar) {
        self.origin = origin
    }

    /**
    - returns:
    Digested bytes as `Data`

    - throws:
    `DescribedError` if something went wrong.
    */
    public func value() throws -> Data {
        return try Data(
            SHA3(
                variant: .keccak256
            ).calculate(
                for: Array(
                    origin.value()
                )
            )
        )
    }

}
