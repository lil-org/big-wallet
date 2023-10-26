// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

extension NSDecimalNumber {
    
    convenience init?(hexString: String) {
        let hexString = hexString.cleanHex
        
        let chunkSize = 8
        let multiplier = NSDecimalNumber(mantissa: 1 << (chunkSize * 4), exponent: 0, isNegative: false)

        var decimalValue = NSDecimalNumber(value: 0)

        var startIndex = hexString.startIndex

        while startIndex < hexString.endIndex {
            let endIndex = hexString.index(startIndex, offsetBy: chunkSize, limitedBy: hexString.endIndex) ?? hexString.endIndex
            let chunk = hexString[startIndex..<endIndex]

            guard let chunkValue = UInt32(chunk, radix: 16) else { return nil }

            decimalValue = decimalValue.multiplying(by: multiplier).adding(NSDecimalNumber(value: chunkValue))
            startIndex = endIndex
        }
        
        self.init(decimal: decimalValue.decimalValue)
    }
    
}
