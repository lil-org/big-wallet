// Copyright © 2023 Tokenary. All rights reserved.

import BigInt

extension BigInt {
    
    init?(hexString: String) {
        self.init(hexString.cleanHex, radix: 16)
    }
    
    var eth: String {
        return NSDecimalNumber(string: String(self)).multiplying(byPowerOf10: -18).stringValue
    }
    
    var gwei: String {
        return NSDecimalNumber(string: String(self)).multiplying(byPowerOf10: -9).stringValue
    }
    
    var wei: String {
        return String(self)
    }
    
}
