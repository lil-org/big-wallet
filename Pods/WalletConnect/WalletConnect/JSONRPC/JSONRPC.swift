// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation

let JSONRPCVersion = "2.0"

struct JSONRPCError: Error, Codable {
    let code: Int
    let message: String
}

struct JSONRPCRequest<T: Codable>: Codable {
    let id: Int64
    let jsonrpc = JSONRPCVersion
    let method: String
    let params: T
}

struct JSONRPCResponse<T: Codable>: Codable {
    let jsonrpc = JSONRPCVersion
    let id: Int64
    let result: T

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
        case error
    }

    init(id: Int64, result: T) {
        self.id = id
        self.result = result
    }
}

struct JSONRPCErrorResponse: Codable {
    let jsonrpc = JSONRPCVersion
    let id: Int64
    let error: JSONRPCError
}

extension JSONRPCResponse {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(result, forKey: .result)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let error = try values.decodeIfPresent(JSONRPCError.self, forKey: .error) {
            throw error
        }
        self.id = try values.decode(Int64.self, forKey: .id)
        self.result = try values.decode(T.self, forKey: .result)
    }
}

public func generateId() -> Int64 {
    return Int64(Date().timeIntervalSince1970) * 1000
}
