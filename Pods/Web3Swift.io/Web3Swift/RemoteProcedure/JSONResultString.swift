//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// JSONResultString.swift
//
// Created by Timofey Solonin on 25/05/2018
//

import Foundation

/** "result" field as string of a json object */
public final class JSONResultString: StringScalar {

    private let json: RemoteProcedure

    /**
    Ctor

    - parameters:
        - json: json containing string in a "result" field
    */
    public init(
        json: RemoteProcedure
    ) {
        self.json = json
    }

    /**
    - returns:
    "result" field of a json as a string
    */
    public func value() throws -> String {
        return try json.call()["result"].string()
    }

}