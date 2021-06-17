// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation
import CryptoSwift

extension Data {
    var hex: String {
        return self.toHexString()
    }
}

extension JSONEncoder {
    func encodeAsUTF8<T>(_ value: T) -> String where T : Encodable {
        guard let data = try? self.encode(value),
            let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}
