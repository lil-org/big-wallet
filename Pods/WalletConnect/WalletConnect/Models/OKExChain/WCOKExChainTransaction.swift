// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation

public struct WCOKExChainTransaction: Codable {
    public let from: String?
    public let to: String?
    public let value: String?
    public let gasLimit: String?
    public let gasPrice: String?
    public let accountNumber: String?
    public let sequenceNumber: String?
    public let symbol: String?
    public let memo: String?
    public let decimalNum: String?
    public let contractAddress: String?
    public let data: String?
}
