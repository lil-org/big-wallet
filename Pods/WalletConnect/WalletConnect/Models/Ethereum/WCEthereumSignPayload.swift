// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation

public enum WCEthereumSignPayload {
    case sign(data: Data, raw: [String])
    case personalSign(data: Data, raw: [String])
    case signTypeData(id: Int64, data: Data, raw: [String])
}

extension WCEthereumSignPayload: Decodable {
    private enum Method: String, Decodable {
        case eth_sign
        case personal_sign
        case eth_signTypedData
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case method
        case params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let method = try container.decode(Method.self, forKey: .method)
        let params = try container.decode([AnyDecodable].self, forKey: .params)
        guard params.count > 1 else { throw WCError.badJSONRPCRequest }
        let strings = params.compactMap { $0.value as? String }
        switch method {
        case .eth_sign:
            self = .sign(data: Data(hex: strings[1]), raw: strings)
        case .personal_sign:
            self = .personalSign(data: Data(hex: strings[0]), raw: strings)
        case .eth_signTypedData:
            let id = try container.decode(Int64.self, forKey: .id)
            let address = params[0].value as? String ?? ""
            if let string = params[1].value as? String,
                let data = string.data(using: .utf8) {
                self = .signTypeData(id: id, data: data, raw: [address, string])
            } else if let dict = params[1].value as? [String: Any] {
                let data = try JSONSerialization.data(withJSONObject: dict, options: [])
                let json = String(data: data, encoding: .utf8) ?? ""
                self = .signTypeData(id: id, data: data, raw: [address, json])
            } else {
                throw WCError.badJSONRPCRequest
            }
        }
    }

    public var method: String {
        switch self {
        case .sign: return Method.eth_sign.rawValue
        case .personalSign: return Method.personal_sign.rawValue
        case .signTypeData: return Method.eth_signTypedData.rawValue
        }
    }

    public var message: String {
        switch self {
        case .sign(_, let raw):
            return raw[1]
        case .personalSign(let data, let raw):
            return String(data: data, encoding: .utf8) ?? raw[0]
        case .signTypeData(_, _, let raw):
            return raw[1]
        }
    }
}
