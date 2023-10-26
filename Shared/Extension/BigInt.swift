// Copyright © 2023 Tokenary. All rights reserved.

import BigInt

extension BigInt {
    
    init?(hexString: String) {
        self.init(hexString.cleanHex, radix: 16)
    }
    
}
