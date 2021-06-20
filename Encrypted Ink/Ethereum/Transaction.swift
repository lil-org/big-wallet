// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

struct Transaction {
    let from: String
    let to: String
    let nonce: String?
    let gasPrice: String?
    let gas: String?
    let value: String?
    let data: String
}
