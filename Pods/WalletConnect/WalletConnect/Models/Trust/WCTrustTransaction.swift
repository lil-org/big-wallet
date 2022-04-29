// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation

public struct WCTrustTransaction: Codable {
    public let network: UInt32
    public let transaction: String

    public init(network: UInt32, transaction: String) {
        self.network = network
        self.transaction = transaction
    }
}
