// ∅ 2026 lil org

import Foundation

extension FixedWidthInteger {
    
    init?(hexString: String) {
        self.init(hexString.cleanHex, radix: 16)
    }
    
}
