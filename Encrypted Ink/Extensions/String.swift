// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation

extension String {
    
    var maybeJSON: Bool {
        return hasPrefix("{") && hasSuffix("}") && count > 3
    }
    
}
