//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// BytesAsCollection.swift
//
// Created by Timofey Solonin on 19/05/2018
//

import Foundation

/** Bytes as a collection of UInt8 byte pieces */
public final class BytesAsCollection: CollectionScalar<UInt8> {

    private let origin: BytesScalar

    /**
    Ctor

    - parameters:
        - origin: bytes to represent as a collection
    */
    public init(origin: BytesScalar) {
        self.origin = origin
    }

    /**
    - returns:
    A collection of bytes as `Array<UInt8>`
    */
    public override func value() throws -> [UInt8] {
        return try Array<UInt8>(
            origin.value()
        )
    }

}