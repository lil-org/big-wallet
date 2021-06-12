//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// VerifiedProcedure.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation
import SwiftyJSON

//swiftlint:disable cyclomatic_complexity

/** json rpc error code as described in http://www.jsonrpc.org/specification#error_object */
internal final class JSONRPCErrorCode {

    private let code: Int

    /**
    Ctor

    - parameters:
        - code: code of the error
    */
    public init(code: Int) {
        self.code = code
    }

    /**
    - returns:
    Code number followed by the description
    */
    internal func value() -> String {
        let value: String
        switch code {
        case -32700:
            value = "Parse error - Invalid JSON was received by the server. An error occurred on the server while parsing the JSON text."
        case -32600:
            value = "Invalid Request - The JSON sent is not a valid Request object."
        case -32601:
            value = "Method not found - The method does not exist / is not available."
        case -32602:
            value = "Invalid params - Invalid method parameter(s)."
        case -32603:
            value = "Internal error - Internal JSON-RPC error."
        case (-32099)...(-32000):
            value = "Custom error"
        default:
            value = "Unknown error"
        }
        return "(\(code)) \(value)"
    }

}

/** Detailed error of a json rpc response error */
internal final class JSONError: DescribedError {

    private let error: JSON

    /**
    Ctor

    - parameters:
        - error: json of a failing response
    */
    public init(error: JSON) {
        self.error = error
    }

    //TODO: In case no error code is identified the JSONRPCErrorCode ctor is stubbed with 0 to display "Unknown error". This should be resolved in JSONRPCErrorCode itself but without optionals.
    /**
    - returns:
    Detailed description of a json rpc error
    */
    internal var description: String {
        if let message = error["error"]["message"].string {
            return [
                "Code: \(JSONRPCErrorCode(code: error["error"]["code"].int ?? 0).value()), ",
                "Message: \(message), ",
                "Data: \(error["error"]["data"].description)"
            ].joined()
        } else {
            return "There was no error in JSON. Here is the dump instead: \(error.debugDescription)"
        }
    }

}

//FIXME: This is a temporary workaround to allow throwing errors communicated by network. It is definitely possible to make this check perform only when the "result" was not found by reimplementing JSON.
/** Procedure that throws in case JSON RPC responded with an error */
public final class VerifiedProcedure: RemoteProcedure {

    private let origin: RemoteProcedure

    /**
    Ctor

    - parameters:
        - origin: procedure to verify
    */
    public init(origin: RemoteProcedure) {
        self.origin = origin
    }

    /**
    - returns:
    JSON that contains "result"

    - throws:
    `DescribedError` if json did not contain "result"
    */
    public func call() throws -> JSON {
        let json = try origin.call()
        guard json["result"].exists() else {
            throw JSONError(
                error: json
            )
        }
        return json
    }

}
