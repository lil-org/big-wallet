// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation

public struct WCBinanceTransferOrder: WCBinanceOrderMessage, Codable {
    public struct Message: Codable {
        public struct Coin: Codable {
            public let amount: Int64
            public let denom: String
        }
        public struct Item: Codable {
            public let address: String
            public let coins: [Coin]
        }
        public let inputs: [Item]
        public let outputs: [Item]
    }

    public let account_number: String
    public let chain_id: String
    public let data: String?
    public let memo: String
    public let msgs: [Message]
    public let sequence: String
    public let source: String

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(account_number, forKey: .account_number)
        try container.encode(chain_id, forKey: .chain_id)
        try container.encode(data, forKey: .data)
        try container.encode(memo, forKey: .memo)
        try container.encode(msgs, forKey: .msgs)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(source, forKey: .source)
    }
}
