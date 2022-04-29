//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// SimpleProcedure.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

/** Anonymous procedure */
public final class SimpleProcedure: RemoteProcedure {

    private let json: () throws -> (JSON)

    /**
    Ctor

    - parameters:
        - json: closure representation of a json returned by the `call` method
    */
    public init(json: @escaping () throws -> (JSON)) {
        self.json = json
    }

    /**
    Ctor

    - parameters:
        - json: json returned by the `call` method
    */
    public convenience init(json: JSON) {
        self.init(json: { json })
    }

    /**
    - returns:
    `JSON` of the procedure

    - throws:
    `DescribedError` if something went wrong
    */
    public func call() throws -> JSON {
        return try json()
    }

}
