// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

extension UInt {
    
    init?(hexString: String) {
        self.init(hexString, radix: 16)
    }
    
}
