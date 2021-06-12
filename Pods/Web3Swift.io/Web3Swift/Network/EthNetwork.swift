//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// EthNetwork.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

internal final class IncorrectUrlStringError: DescribedError {

    private let url: String

    public init(url: String) {
        self.url = url
    }

    internal var description: String {
        return "Incorrect URL string \"\(self.url)\""
    }

}

internal final class InvalidIDResponseError: DescribedError {

    private let response: String
    public init(response: String) {
        self.response = response
    }

    internal var description: String {
        return "net_version call was expected to return \"result\" as decimal in a string but it was \(response)"
    }

}

public class EthNetwork: Network {
    
    private let session: URLSession
    private let url: String
    private let headers: Dictionary<String, String>
    
    public init(session: URLSession, url: String, headers: Dictionary<String, String>) {
        self.session = session
        self.url = url
        self.headers = headers
    }

    /**
    - returns:
    id of a network

    - throws:
    `DescribedError` if something went wrong.
    */
    public func id() throws -> IntegerScalar {
        let result = try ChainIDProcedure(
            network: EthNetwork(
                session: self.session,
                url: self.url,
                headers: self.headers
            )
        ).call()["result"].string()
        guard let id = Int(result) else {
            throw InvalidIDResponseError(
                response: result
            )
        }
        return SimpleInteger(
            integer: id
        )
    }

    // "id" : 16180 - see https://en.wikipedia.org/wiki/Golden_ratio
    public func call(method: String, params: Array<EthParameter>) throws -> Data {
        guard let url = URL(string: url) else {
            throw IncorrectUrlStringError(
                url: self.url
            )
        }
        return try session.data(
            from: URLPostRequest(
                url: url,
                body: JSON(
                    dictionary: [
                        "jsonrpc" : "2.0",
                        "method" : method,
                        "params" : params.map {
                            try $0.value()
                        },
                        "id" : 16180
                    ]
                ).rawData(),
                headers: headers
            ).toURLRequest()
        )
    }
    
}
