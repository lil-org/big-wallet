//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// UTF8String.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import CryptoSwift
import Foundation

internal final class NotUTF8BytesError: DescribedError {

    private let bytes: Data
    public init(bytes: Data) {
        self.bytes = bytes
    }

    internal var description: String {
        return "Bytes 0x\(bytes.toHexString()) do not produce a valid utf8 string"
    }

}

/** utf8 string */
public final class UTF8String: StringScalar {

    private let bytes: BytesScalar
    /**
    Ctor

    - parameters:
        - bytes: bytes representation of a utf8 string
    */
    public init(bytes: BytesScalar) {
        self.bytes = bytes
    }

    /**
    - returns:
    UTF8 encoded string
    
    - throws:
    `DescribedError` if something went wrong. I.e. if string was not utf8
    */
    public func value() throws -> String {
        let bytes = try self.bytes.value()
        guard let value = String(
            bytes: bytes,
            encoding: String.Encoding.utf8
        ) else {
            throw NotUTF8BytesError(
                bytes: bytes
            )
        }
        return value
    }

}
