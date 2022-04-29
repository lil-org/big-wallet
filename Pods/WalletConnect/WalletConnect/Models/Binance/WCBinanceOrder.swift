// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation

public protocol WCBinanceOrder {
    var encoded: Data { get }
    var encodedString: String { get }
}

public protocol WCBinanceOrderMessage: WCBinanceOrder {
    associatedtype Message
    var account_number: String { get }
    var chain_id: String { get }
    var data: String? { get }
    var memo: String { get }
    var msgs: [Message] { get }
    var sequence: String { get }
    var source: String { get }
}

public struct WCBinanceOrderSignature: Codable {
    public let signature: String
    public let publicKey: String

    public init(signature: String, publicKey: String) {
        self.signature = signature
        self.publicKey = publicKey
    }
}

public struct WCBinanceTxConfirmParam: Codable {
    public let ok: Bool
    public let errorMsg: String?
}
