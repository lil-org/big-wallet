// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation

public struct WCPeerMeta: Codable {
    public let name: String
    public let url: String
    public let description: String
    public let icons: [String]

    public init(name: String, url: String, description: String = "", icons: [String] = []) {
        self.name = name
        self.url = url
        self.description = description
        self.icons = icons
    }
}
