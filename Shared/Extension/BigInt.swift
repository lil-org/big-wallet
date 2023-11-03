// Copyright © 2023 Tokenary. All rights reserved.

import Foundation
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
    
    var gwei: String {
        let gweiDecimal = decimal.multiplying(byPowerOf10: -9)
        let uintValue = gweiDecimal.uintValue
        if uintValue > 0 {
            return String(uintValue)
        } else {
            let formatter = NumberFormatter()
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 1
            return formatter.string(from: gweiDecimal) ?? "0"
        }
    }
    
}
