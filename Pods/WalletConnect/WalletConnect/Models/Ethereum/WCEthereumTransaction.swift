// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation

public struct WCEthereumTransaction: Codable {
    public let from: String
    public let to: String?
    public let nonce: String?
    public let gasPrice: String?
    public let gas: String?
    public let gasLimit: String? // legacy gas limit
    public let value: String?
    public let data: String
}
