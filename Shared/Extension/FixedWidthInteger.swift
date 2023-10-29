// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

extension FixedWidthInteger {
    
    init?(hexString: String) {
        self.init(hexString.cleanHex, radix: 16)
    }
    
}
