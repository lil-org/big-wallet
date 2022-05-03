//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// PersonalMessageBytes.swift
//
// Created by Vadim Koleoshkin on 10/05/2019
//

/** Bytes representing Ethereum personal message */
public final class PersonalMessageBytes: BytesScalar {
    
    private let message: StringScalar

    /**
    Ctor

    - parameters:
     - message: input message.
    */
    public init(message: StringScalar) {
        self.message = message
    }
    
    /**
     Ctor
     
     - parameters:
        - message: string input message.
     */
    public convenience init(message: String) {
        self.init(
            message: SimpleString(
                string: message
            )
        )
    }
    
    public func value() throws -> Data {
        let message = try self.message.value()
        return try ConcatenatedBytes(
            bytes: [
                //Ethereum prefix
                UTF8StringBytes(
                    string: "\u{19}Ethereum Signed Message:\n"
                ),
                //Message length
                UTF8StringBytes(
                    string: String(message.count)
                ),
                //Message
                UTF8StringBytes(
                    string: message
                )
            ]
        ).value()
    }
}
