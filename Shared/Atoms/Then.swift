// Copyright © 2022 Tokenary. All rights reserved.
// Simple applicator

import Foundation

protocol Then {}

extension Then where Self: AnyObject {
    @inlinable func then(_ block: (Self) -> Void) -> Self {
        block(self)
        return self
    }
}

extension NSObject: Then {}
