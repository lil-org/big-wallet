// Copyright © 2023 Tokenary. All rights reserved.

import BigInt

extension BigInt {
    
    init?(hexString: String) {
        self.init(hexString.cleanHex, radix: 16)
    }
    
    private var decimal: NSDecimalNumber {
        return NSDecimalNumber(string: String(self))
    }
    
    var eth: String {
        return decimal.multiplying(byPowerOf10: -18).stringValue
    }
    
    var ethDouble: Double {
        return decimal.multiplying(byPowerOf10: -18).doubleValue
    }
    
    var gweiUInt: UInt {
        return decimal.multiplying(byPowerOf10: -9).uintValue
    }
    
}
