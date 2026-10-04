// ∅ 2026 lil org

import CoreGraphics

extension CGFloat {
    static func pixel(displayScale: CGFloat) -> CGFloat {
#if os(visionOS)
        1
#else
        1 / Swift.max(displayScale, 1)
#endif
    }
}
