// ∅ 2025 lil org

import Foundation
import BigInt

extension BigInt {
    
    init?(hexString: String) {
        self.init(hexString.cleanHex, radix: 16)
    }
    
    private var decimal: NSDecimalNumber {
        return NSDecimalNumber(string: String(self))
    }
    
    func eth(shortest: Bool = false) -> String {
        let ethDecimal = decimal.multiplying(byPowerOf10: -18)
        let formatter = NumberFormatter()
        
        if shortest {
            formatter.minimumFractionDigits = 3
            formatter.maximumFractionDigits = 6
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 2
        } else {
            formatter.minimumFractionDigits = 6
            formatter.maximumFractionDigits = 9
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 10
        }
        
        return formatter.string(from: ethDecimal) ?? .zero
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
            return formatter.string(from: gweiDecimal) ?? .zero
        }
    }
    
}
