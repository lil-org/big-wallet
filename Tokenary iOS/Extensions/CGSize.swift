// Copyright © 2022 Tokenary. All rights reserved.

import CoreGraphics

extension CGSize {
    static func += (lhs: inout CGSize, rhs: CGFloat) {
        lhs = CGSize(width: lhs.width + rhs, height: lhs.height + rhs)
    }
    
    static func += (lhs: inout CGSize, rhs: Double) {
        lhs = CGSize(width: lhs.width + rhs, height: lhs.height + rhs)
    }
}
