//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// SimpleRLP.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

public final class SimpleRLP: RLP {

    private let bytes: BytesScalar
    private let appendix: RLPAppendix

    private init(bytes: BytesScalar, appendix: RLPAppendix) {
        self.bytes = bytes
        self.appendix = appendix
    }

    public convenience init(bytes: BytesScalar) {
        self.init(
            bytes: bytes,
            appendix: RLPBytesAppendix()
        )
    }

    public convenience init(bytes: Data) {
        self.init(
            bytes: SimpleBytes(
                bytes: bytes
            )
        )
    }

    public convenience init(bytes: Array<UInt8>) {
        self.init(
            bytes: SimpleBytes(
                bytes: bytes
            )
        )
    }

    public convenience init(rlps: [RLP]) {
        self.init(
            bytes: ConcatenatedBytes(bytes: rlps),
            appendix: RLPCollectionAppendix()
        )
    }

    public func value() throws -> Data {
        return try appendix.applying(to: bytes.value())
    }

}
